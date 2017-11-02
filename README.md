# Ogg

[![Build Status](https://travis-ci.org/staticfloat/Ogg.jl.svg?branch=master)](https://travis-ci.org/staticfloat/Ogg.jl)

Basic bindings to `libogg` to read Ogg bitstreams.  Basic operation is to use `load()` to read in an array of packets which can then be decoded by whatever higher-level codec can use them (such as [`Opus.jl`](https://github.com/staticfloat/Opus.jl)), or use `save()` to write out a set of packets and their respective granule positions.  Manual use of this package is unusual, however if you are curious as to how `.ogg` files work, this package can act as a nice debugging tool.

To look into details of an `.ogg` file such as its actual pages, you must keep track of the `OggDecoder` object so you can inspect its internal fields `pages` and `packets`.  The definition of `load()` is roughly equivalent to:

```julia
dec = OggDecoder()
Ogg.decode_all_pages(dec, fio)
Ogg.decode_all_packets(dec, fio)
```

Where `fio` is an `IO` object you wish to decode.  The fields `dec.pages` and `dec.packets` now contains much information about the `.ogg` file you have just decoded.

The [Ogg Wikipedia Entry](https://en.wikipedia.org/wiki/Ogg) is a useful introduction to the Ogg format, but for most users it should be sufficient to understand a few terms.

* Physical Bitstream: The actual data read from an Ogg stream on disk, or read from the network, etc. This gets divided into a series of pages.
* Logical Bitstream: Data meant to be decoded by a codec. A physical bitstream may be made up of multiple logical bistreams, e.g. a movie might be encoded as 2 logical bistreams, one representing the audio and the other the video.
* Elementary Bitstream: A sequence of pages that carry the data for a single logical bitstream. If there is only one logical bitstream than the elementary and physical bistreams are the same.
* Page: A unit of data in the physical and elementary bitstreams. Each page will belong to a single logical bitstream, so the physical bitstream is made up of the pages of the logical bitstreams interleaved. Pages can be of varying size up to about 64kB.
* Packet: A unit of data in a logical stream. A page can contain multiple packets, but packets can also span across page boundaries, or even multiple pages.
* Segment: A piece of a packet. A packet is split into a number of 255-byte segments, with the final segment being smaller than 255 bytes. A segment can be 0 bytes long, so a 510 bytes packet would be split into 3 segments of length 255, 255, and 0. Each page contains up to 255 segments, each of which can be up to 255 bytes.

The images [here](https://xiph.org/ogg/doc/oggstream.html) are useful for visualizing the above definitions.

## New API Ideas

We want to support streaming read/write, with the following API:

```julia
julia> dec = OggDecoder("filename.ogg") # should also support using an `IO`

# generally users don't care about pages, but we'll use this internally
julia> for page in pages(dec)
    ...
end

julia> streams(dec)
3-element Array{OggPacketStream,1}:
 0.578832
 0.411074
 0.587217

```

### Issues:

* How to handle concatenated files
*
