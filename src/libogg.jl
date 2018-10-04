# this file has the low-level libogg types and wrappers for ccall functions. It
# provides some thin convenience wrappers but matches the same basic API as
# libogg

# docstrings are mostly copied from https://xiph.org/ogg/doc/libogg/reference.html

# These types all shadow libogg datatypes, hence they are all immutable

"""
The ogg_sync_state struct tracks the synchronization of the current page.

It is used during decoding to track the status of data as it is read in,
synchronized, verified, and parsed into pages belonging to the various logical
bistreams in the current physical bitstream link.
"""
struct OggSyncState
    # Pointer to buffered stream data
    data::Ptr{UInt8}
    # Current allocated size of the stream buffer held in *data
    storage::Cint
    # The number of valid bytes currently held in *data; functions as the buffer head pointer
    fill::Cint
    # The number of bytes at the head of *data that have already been returned as pages;
    # functions as the buffer tail pointer
    returned::Cint

    # Synchronization state flag; nonzero if sync has not yet been attained or has been lost
    unsynced::Cint
    # If synced, the number of bytes used by the synced page's header
    headerbytes::Cint
    # If synced, the number of bytes used by the synced page's body
    bodybytes::Cint

    function OggSyncState()
        syncstate = new()
        status = ccall((:ogg_sync_init, libogg), Cint, (Ref{OggSyncState},), syncstate)
        if status != 0
            error("ogg_sync_init() failed: This should never happen")
        end

        syncstate
    end
end

"""
This function is used to free the internal storage of an ogg_sync_state struct
and resets the struct to the initial state. To free the entire struct,
ogg_sync_destroy should be used instead. In situations where the struct needs to
be reset but the internal storage does not need to be freed, ogg_sync_reset
should be used.
"""
function ogg_sync_clear(sync::OggSyncState)
    ccall((:ogg_sync_clear,libogg), Cint, (Ref{OggSyncState},), sync)
end


"""
The ogg_page struct encapsulates the data for an Ogg page.

Ogg pages are the fundamental unit of framing and interleave in an ogg
bitstream. They are made up of packet segments of 255 bytes each. There can be
as many as 255 packet segments per page, for a maximum page size of a little
under 64 kB. This is not a practical limitation as the segments can be joined
across page boundaries allowing packets of arbitrary size. In practice many
applications will not completely fill all pages because they flush the
accumulated packets periodically order to bound latency more tightly.
"""
struct OggPage
    # Pointer to the page header for this page
    header::Ptr{UInt8}
    # Length of the page header in bytes
    header_len::Clong
    # Pointer to the data for this page
    body::Ptr{UInt8}
    # Length of the body data in bytes
    body_len::Clong

    # zero-constructor
    OggPage() = new(C_NULL, 0, C_NULL, 0)
end

# function read(page::OggPage)
#     GC.@preserve page begin
#         header_ptr = unsafe_wrap(Array, page.header, page.header_len)
#         body_ptr = unsafe_wrap(Array, page.body, page.body_len)
#         return vcat(header_ptr, body_ptr)
#     end
# end
#
function show(io::IO, x::OggPage)
    write(io, "OggPage ID: $(ogg_page_serialno(x)), length $(x.body_len) bytes")
end

# This const here so that we don't use ... syntax in new()
const oss_zero_header = tuple(zeros(UInt8, 282)...)

"""
The ogg_stream_state struct tracks the current encode/decode state of the
current logical bitstream.
"""
struct OggStreamState
    # Pointer to data from packet bodies
    body_data::Ptr{UInt8}
    # Storage allocated for bodies in bytes (filled or unfilled)
    body_storage::Clong
    # Amount of storage filled with stored packet bodies
    body_fill::Clong
    # Number of elements returned from storage
    body_returned::Clong

    # String of lacing values for the packet segments within the current page
    # Each value is a byte, indicating packet segment length
    lacing_vals::Ptr{Cint}
    # Pointer to the lacing values for the packet segments within the current page
    granule_vals::Int64
    # Total amount of storage (in bytes) allocated for storing lacing values
    lacing_storage::Clong
    # Fill marker for the current vs. total allocated storage of lacing values for the page
    lacing_fill::Clong
    # Lacing value for current packet segment
    lacing_packet::Clong
    # Number of lacing values returned from lacing_storage
    lacing_returned::Clong

    # Temporary storage for page header during encode process, while the header is being created
    header::NTuple{282,UInt8}
    # Fill marker for header storage allocation. Used during the header creation process
    header_fill::Cint

    # Marker set when the last packet of the logical bitstream has been buffered
    e_o_s::Cint
    # Marker set after we have written the first page in the logical bitstream
    b_o_s::Cint
    # Serial number of this logical bitstream
    serialno::Clong
    # Number of the current page within the stream
    pageno::Cint
    # Number of the current packet
    packetno::Int64
    # Exact position of decoding/encoding process
    granulepos::Int64

    # zero-constructor
    function OggStreamState()
        streamstate = new()
        status = ccall((:ogg_stream_init,libogg), Cint,
                       (Ref{OggStreamState}, Cint), streamstate, serial)
        if status != 0
            error("ogg_stream_init() failed with status $status")
        end
    end
end

"""
This function clears and frees the internal memory used by the ogg_stream_state
struct, but does not free the structure itself. It is safe to call
ogg_stream_clear on the same structure more than once.
"""
function ogg_stream_clear(stream::OggStreamState)
    ccall((:ogg_stream_clear,libogg), Cint, (Ref{OggStreamState},), stream)
end

struct OggPacket
    # Pointer to the packet's data. This is treated as an opaque type by the ogg layer
    packet::Ptr{UInt8}
    # Indicates the size of the packet data in bytes. Packets can be of arbitrary size
    bytes::Clong
    # Flag indicating whether this packet begins a logical bitstream
    # 1 indicates this is the first packet, 0 indicates any other position in the stream
    b_o_s::Clong
    # Flag indicating whether this packet ends a bitstream
    # 1 indicates the last packet, 0 indicates any other position in the stream
    e_o_s::Clong

    # A number indicating the position of this packet in the decoded data
    # This is the last sample, frame or other unit of information ('granule')
    # that can be completely decoded from this packet
    granulepos::Int64
    # Sequential number of this packet in the ogg bitstream
    packetno::Int64
end
# zero-constructor
OggPacket() = OggPacket(C_NULL, 0, 0, 0, 0, 0)

function show(io::IO, x::OggPacket)
    write(io,"OggPacket ID: $(x.packetno), length $(x.bytes) bytes")
end

# """
#     ogg_sync_buffer(dec::OggDecoder, size)
#
# Provide a buffer for writing new raw data into from the physical bitstream.
#
# Buffer space which has already been returned is cleared, and the buffer is
# extended as necessary by the size plus some additional bytes. Within the current
# implementation, an extra 4096 bytes are allocated, but applications should not
# rely on this additional buffer space.
#
# The buffer exposed by this function is empty internal storage from the
# `ogg_sync_state` struct, beginning at the fill mark within the struct.
#
# After copying data into this buffer you should call `ogg_sync_wrote` to tell the
# `ogg_sync_state` struct how many bytes were actually written, and update the
# fill mark.
#
# Returns an `Array` wrapping the provided buffer
#
# (docs adapted from https://xiph.org/ogg/doc/libogg/ogg_sync_buffer.html)
# """
# function ogg_sync_buffer(dec::OggDecoder, size)
#     syncref = Ref{OggSyncState}(dec.sync_state)
#     buffer = ccall((:ogg_sync_buffer,libogg), Ptr{UInt8}, (Ref{OggSyncState}, Clong), syncref, size)
#     dec.sync_state = syncref[]
#     if buffer == C_NULL
#         error("ogg_sync_buffer() failed: returned buffer NULL")
#     end
#     return unsafe_wrap(Array, buffer, size)
# end

# """
#     ogg_sync_wrote(dec::OggDecoder, size)
#
# Tell the ogg_sync_state struct how many bytes we wrote into the buffer.
#
# The general proceedure is to request a pointer into an internal ogg_sync_state
# buffer by calling ogg_sync_buffer(). The buffer is then filled up to the
# requested size with new input, and ogg_sync_wrote() is called to advance the
# fill pointer by however much data was actually available.
# """
# function ogg_sync_wrote(dec::OggDecoder, size)
#     syncref = Ref{OggSyncState}(dec.sync_state)
#     status = ccall((:ogg_sync_wrote,libogg), Cint, (Ref{OggSyncState}, Clong), syncref, size)
#     dec.sync_state = syncref[]
#     if status != 0
#         error("ogg_sync_wrote() failed: error code $status")
#     end
#     nothing
# end

# """
#     ogg_sync_pageout(dec::OggDecoder)::Nullable{OggPage}
#
# Takes the data stored in the buffer of the decoder and inserts them into an
# ogg_page. Note that the payload data in the page is not copied, so the memory
# the OggPage points to is still contained within the ogg_sync_state struct.
#
# Caution:This function should be called before reading into the buffer to ensure
# that data does not remain in the ogg_sync_state struct. Failing to do so may
# result in a memory leak. See the example code below for details.
#
# Returns a new OggPage if it was available, or null if not, wrapped in a
# `Nullable{OggPage}`.
#
# (docs adapted from https://xiph.org/ogg/doc/libogg/ogg_sync_pageout.html)
# """
# function ogg_sync_pageout(dec::OggDecoder)
#     syncref = Ref(dec.sync_state)
#     pageref = Ref(OggPage())
#     status = ccall((:ogg_sync_pageout,libogg), Cint, (Ref{OggSyncState}, Ref{OggPage}), syncref, pageref)
#     dec.sync_state = syncref[]
#     if status == 1
#         return Nullable{OggPage}(pageref[])
#     else
#         return Nullable{OggPage}()
#     end
# end

"""
    ogg_page_serialno(page::OggPage)

Returns the serial number of the given page
"""
function serial(page::OggPage)
    pageref = Ref{OggPage}(page)
    return Clong(ccall((:ogg_page_serialno,libogg), Cint, (Ref{OggPage},), pageref))
end

"""
    ogg_page_eos(page::OggPage)

Indicates whether the given page is an end-of-stream
"""
function eos(page::OggPage)
    pageref = Ref{OggPage}(page)
    return ccall((:ogg_page_eos,libogg), Cint, (Ref{OggPage},), pageref) != 0
end

"""
    ogg_page_bos(page::OggPage)

Indicates whether the given page is an end-of-stream
"""
function bos(page::OggPage)
    pageref = Ref{OggPage}(page)
    return ccall((:ogg_page_eos,libogg), Cint, (Ref{OggPage},), pageref) != 0
end


"""
Send a page in, return the serial number of the stream that we just decoded.

This copies the data that the OggPage points to (contained within the
`ogg_sync_state` struct) into the `ogg_stream_state` struct.
"""
function ogg_stream_pagein(streamref::Ref{OggStreamState}, page::OggPage)
    pageref = Ref(page)
    status = ccall((:ogg_stream_pagein,libogg), Cint,
                   (Ref{OggStreamState}, Ref{OggPage}), streamref, pageref)
    if status != 0
        error("ogg_stream_pagein() failed with status $status")
    end
    nothing
end

# note that this doesn't actually copy the data into the packet, it just makes
# the packet point to the data within the stream
function ogg_stream_packetout(streamref::Ref{OggStreamState}, retry=false)
    packetref = Ref{OggPacket}(OggPacket())
    status = ccall((:ogg_stream_packetout,libogg), Cint,
                   (Ref{OggStreamState}, Ref{OggPacket}), streamref, packetref)
    if status == 1
        return packetref[]
    else
        # Is our status -1?  That means we're desynchronized and should try again, at least once
        if status == -1 && !retry
            return ogg_stream_packetout(dec, serial; retry = true)
        end
        return nothing
    end
end
