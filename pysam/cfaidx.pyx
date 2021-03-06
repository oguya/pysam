# cython: embedsignature=True
# cython: profile=True
# adds doc-strings for sphinx
import sys
import os
from cpython cimport array

from cpython cimport PyErr_SetString, \
    PyBytes_Check, \
    PyUnicode_Check, \
    PyBytes_FromStringAndSize

from cpython.version cimport PY_MAJOR_VERSION

from chtslib cimport \
    faidx_nseq, fai_load, fai_destroy, fai_fetch, \
    faidx_fetch_seq, gzopen, gzclose, \
    kseq_init, kseq_destroy, kseq_read

from cutils cimport force_bytes, force_str, charptr_to_str
from cutils cimport encode_filename, from_string_and_size
from cutils cimport _chars_to_array


cdef class FastqProxy
cdef makeFastqProxy(kseq_t * src):
    '''enter src into AlignedRead.'''
    cdef FastqProxy dest = FastqProxy.__new__(FastqProxy)
    dest._delegate = src
    return dest

#####################################################################
# hard-coded constants
cdef int max_pos = 2 << 29

## TODO:
##        add automatic indexing.
##        add function to get sequence names.
cdef class FastaFile:
    '''*(filename)*

    A *FASTA* file. The file is automatically opened.

    This class expects an indexed fasta file and permits
    random access to fasta sequences.
    '''

    def __cinit__(self, *args, **kwargs ):
        self.fastafile = NULL
        self._filename = None
        self._references = None
        self._lengths = None
        self.reference2length = None
        self._open( *args, **kwargs )

    def _isOpen( self ):
        '''return true if samfile has been opened.'''
        return self.fastafile != NULL

    def __len__(self):
        if self.fastafile == NULL:
            raise ValueError("calling len() on closed file")

        return faidx_nseq(self.fastafile)

    def _open(self, filename):
        '''open an indexed fasta file.

        This method expects an indexed fasta file.
        '''

        # close a previously opened file
        if self.fastafile != NULL: self.close()
        self._filename = encode_filename(filename)
        cdef char *cfilename = self._filename
        with nogil:
            self.fastafile = fai_load(cfilename)

        if self.fastafile == NULL:
            raise IOError("could not open file `%s`" % filename)

        # read index
        if not os.path.exists( self._filename + b".fai" ):
            raise ValueError("could not locate index file")

        with open( self._filename + b".fai" ) as inf:
            data = [ x.split("\t") for x in inf ]
            self._references = tuple(x[0] for x in data)
            self._lengths = tuple(int(x[1]) for x in data)
            self.reference2length = dict(zip(self._references, self._lengths))

    def close( self ):
        if self.fastafile != NULL:
            fai_destroy( self.fastafile )
            self.fastafile = NULL

    def __dealloc__(self):
        self.close()

    property filename:
        '''filename associated with this object.'''
        def __get__(self):
            return self._filename

    property references:
        '''tuple with the names of :term:`reference` sequences.'''
        def __get__(self):
            return self._references

    property nreferences:
        '''number of :term:`reference` sequences in the file.'''
        def __get__(self):
            return len(self._references) if self.references else None

    property lengths:
        '''tuple with the lengths of :term:`reference` sequences.'''
        def __get__(self):
            return self._lengths

    def fetch(self,
              reference=None,
              start=None,
              end=None,
              region=None):

        '''*(reference = None, start = None, end = None, region = None)*

        fetch sequences in a :term:`region` using 0-based indexing.

        The region is specified by :term:`reference`, *start* and *end*.

        fetch returns an empty string if the region is out of range or
        addresses an unknown *reference*.

        If *reference* is given and *start* is None, the sequence from the
        first base is returned. Similarly, if *end* is None, the sequence
        until the last base is returned.

        Alternatively, a samtools :term:`region` string can be supplied.
        '''

        if not self._isOpen():
            raise ValueError( "I/O operation on closed file" )

        cdef int length
        cdef char *seq
        cdef char *cregion

        if not region:
            if reference is None:
                raise ValueError('no sequence/region supplied.')
            if start is None:
                start = 0
            if end is None:
                end = max_pos - 1

            if start > end:
                raise ValueError(
                    'invalid region: start (%i) > end (%i)' % (start, end))
            if start == end:
                return b""
            # valid ranges are from 0 to 2^29-1
            if not 0 <= start < max_pos:
                raise IndexError('start out of range (%i)' % start)
            if not 0 <= end < max_pos:
                raise IndexError('end out of range (%i)' % end)
            # note: faidx_fetch_seq has a bug such that out-of-range access
            # always returns the last residue. Hence do not use faidx_fetch_seq,
            # but use fai_fetch instead
            # seq = faidx_fetch_seq(self.fastafile,
            #                       reference,
            #                       start,
            #                       end-1,
            #                       &length)
            region = "%s:%i-%i" % (reference, start+1, end)
            cregion = region
            if PY_MAJOR_VERSION >= 3:
                region = region.encode('ascii')
            with nogil:
                seq = fai_fetch(self.fastafile,
                                cregion,
                                &length)
        else:
            # samtools adds a '\0' at the end
            cregion = region
            with nogil:
                seq = fai_fetch(self.fastafile, cregion, &length)

        # copy to python
        if seq == NULL:
            return b""
        else:
            try:
                py_seq = seq[:length]
            finally:
                free(seq)

        return py_seq

    cdef char * _fetch( self, char * reference, int start, int end, int * length ):
        '''fetch sequence for reference, start and end'''

        with nogil:
            return faidx_fetch_seq(self.fastafile,
                                   reference,
                                   start,
                                   end-1,
                                   length )

    def get_reference_length(self, reference):
        '''return the length of reference.'''
        return self.reference2length[reference]

    def __getitem__(self, reference):
        return self.fetch(reference)

    def __contains__(self, reference):
        '''return true if reference in fasta file.'''
        return reference in self.reference2length


cdef class FastqProxy:
    def __init__(self): pass

    property name:
        def __get__(self):
            return self._delegate.name.s

    property sequence:
        def __get__(self):
            return self._delegate.seq.s

    property comment:
        def __get__(self):
            if self._delegate.comment.l:
                return self._delegate.comment.s
            else:
                return None

    property quality:
        def __get__(self):
            if self._delegate.qual.l:
                return self._delegate.qual.s
            else:
                return None

    cdef cython.str tostring(self):
        if self.comment is None:
            comment = ""
        else:
            comment = " %s" % self.comment

        if self.quality is None:
            return ">%s%s\n%s" % (self.name, comment, self.sequence)
        else:
            return "@%s%s\n%s\n+\n%s" % (self.name, comment,
                                         self.sequence, self.quality)

    def __str__(self):
        return self.tostring()

    cpdef array.array get_quality_array(self, int offset=33):
        '''return quality values as array after subtracting offset.'''
        if self.quality is None:
            return None
        return _chars_to_array(self.quality, offset=offset)

cdef class PersistentFastqProxy:
    """
    Python container for pysam.cfaidx.FastqProxy with persistence.
    Needed to compare multiple fastq records from the same file.

    """
    def __init__(self, FastqProxy FastqRead):
        self.comment = FastqRead.comment
        self.quality = FastqRead.quality
        self.sequence = FastqRead.sequence
        self.name = FastqRead.name

    cdef cython.str tostring(self):
        if self.comment is None:
            comment = ""
        else:
            comment = " %s" % self.comment

        if self.quality is None:
            return ">%s%s\n%s" % (self.name, comment, self.sequence)
        else:
            return "@%s%s\n%s\n+\n%s" % (self.name, comment,
                                         self.sequence, self.quality)

    def __str__(self):
        return self.tostring()

    cpdef array.array get_quality_array(self, int offset=33):
        '''return quality values as array after subtracting offset.'''
        if self.quality is None:
            return None
        return _chars_to_array(self.quality, offset=offset)


cdef class FastxFile:
    '''*(filename)*

    A :term:`fastq` or :term:`fasta` formatted file. The file
    is automatically opened.

    Entries in the file can be both fastq or fasta formatted
    or even a mixture of the two.

    This file object permits iterating over all entries in
    the file. Random access is not implemented. The iteration
    returns objects of type :class:`FastqProxy`

    '''
    def __cinit__(self, *args, **kwargs):
        # self.fastqfile = <gzFile*>NULL
        self._filename = None
        self.entry = NULL
        self._open(*args, **kwargs)

    def _isOpen(self):
        '''return true if samfile has been opened.'''
        return self.entry != NULL

    def _open(self, filename, persist=True):
        '''open a fastq/fasta file in *filename*

        Keyword arguments:
        persist -- if True return a copy of the underlying data (default True).
                   The copy will persist even if the iteration on the file continues.

        '''
        self.close()

        if not os.path.exists(filename):
            raise IOError("no such file or directory: %s" % filename)

        self.persist = persist

        filename = encode_filename(filename)
        cdef char *cfilename = filename
        with nogil:
            self.fastqfile = gzopen(cfilename, "r")
            self.entry = kseq_init(self.fastqfile)
        self._filename = filename

    def close( self ):
        '''close file.'''
        if self.entry != NULL:
            gzclose(self.fastqfile)
            if self.entry:
                kseq_destroy(self.entry)
                self.entry = NULL

    def __dealloc__(self):
        self.close()

    property filename:
        '''filename associated with this object.'''
        def __get__(self):
            return self._filename

    def __iter__(self):
        if not self._isOpen():
            raise ValueError("I/O operation on closed file")
        return self

    cdef kseq_t * getCurrent(self):
        return self.entry

    cdef int cnext(self):
        '''C version of iterator
        '''
        with nogil:
            return kseq_read(self.entry)

    def __next__(self):
        """
        python version of next().
        """
        cdef int l
        with nogil:
            l = kseq_read(self.entry)
        if (l > 0):
            if self.persist:
                return PersistentFastqProxy(makeFastqProxy(self.entry))
            return makeFastqProxy(self.entry)
        else:
            raise StopIteration

# Compatibility Layer for pysam 0.8.1
cdef class FastqFile(FastxFile):
    pass

# Compatibility Layer for pysam < 0.8
cdef class Fastafile(FastaFile):
    pass

__all__ = ["FastaFile",
           "FastqFile",
           "FastxFile",
           "Fastafile"]


