# Ogg

[![Build Status](https://travis-ci.org/staticfloat/Ogg.jl.svg?branch=master)](https://travis-ci.org/staticfloat/Ogg.jl)

Basic bindings to `libogg` to read Ogg bitstreams. Manual use of this package is unusual, however if you are curious as to how `.ogg` files work, this package can act as a nice debugging tool.

## Quick Start

To decode a simple `.ogg` file containing a single stream into its packets, you can simply do:

```julia
packets = OggDecoder("filename.ogg") do oggdec
    collect(eachpacket(oggdec))
end
```

Though this uses some shortcuts and makes assumptions about your file:
1. There is only a single logical stream (in a multiplexed file only the first logical stream will be decoded)
2. The file is not chained (in a chained file only the first "link" will be decoded)

That shortcut syntax is equivalent to:

```julia
# open the file as an IO stream
open("filename.ogg") do phystream
    # Wrap the stream in an OggDecoder
    OggDecoder(phystream) do oggdec
        # open the 1st logical stream
        open(streams(oggdec)[1]) do logstream
            # collect packets using the eachpacket iterator
            collect(eachpacket(logstream))
        end
    end
end
```

## Ogg Concepts

To understand the operation of this package it's helpful to understand a little bit about the Ogg container format. The [Ogg Wikipedia Entry](https://en.wikipedia.org/wiki/Ogg) is a useful introduction to the Ogg format, but for most users it should be sufficient to understand a few terms:

* Physical Bitstream: The actual data read from an Ogg stream on disk, or read from the network, etc. This gets divided into a series of pages.
* Logical Bitstream: Data meant to be decoded by a codec (e.g. Opus or Vorbis). A physical bitstream may be made up of multiple logical bitstreams, e.g. a movie might be encoded as 2 logical bitstreams, one representing the audio and the other the video. Each logical bitstream starts with a page with the `BOS` flag set, and ends with a page with the `EOS` flag. Each logical bitstream also has a serial number that is unique within the physical bitstream, and which marks all its pages.
* Elementary Bitstream: A sequence of pages that carry the data for a single logical bitstream. If there is only one logical bitstream than the elementary and physical bitstreams are the same.
* Page: A unit of data in the physical and elementary bitstreams. Each page will belong to a single logical bitstream, so the physical bitstream is made up of the pages of the logical bitstreams interleaved. Pages can be of varying size up to about 64kB.
* Packet: A unit of data in a logical stream. A page can contain multiple packets, but packets can also span across page boundaries, or even multiple pages.
* Segment: A piece of a packet. A packet is split into a number of 255-byte segments, with the final segment being smaller than 255 bytes. A segment can be 0 bytes long, so a 510 bytes packet would be split into 3 segments of length 255, 255, and 0. Each page contains up to 255 segments, each of which can be up to 255 bytes. By breaking a packet into segments it can span across multiple pages.

The images [here](https://xiph.org/ogg/doc/oggstream.html) are useful for visualizing the above definitions.

## Types

### `OggDecoder`

The `OggDecoder` type decodes a physical bitstream (from disk, or a network connection, etc.). `readpage(::OggDecoder)` will give you the next page.

`streams(::OggDecoder)` returns a list of all the logical streams contained in the Ogg file. Each logical stream is represented by an `OggLogicalStream`. You must call `open` on the stream before you can start reading from it.

Rather than (or in addition to) using `readpage` you can also iterate through the pages using the `eachpage(::OggDecoder)` and `eachpage(::OggLogicalStream)` methods (to get the pages of the physical and elementary bitstreams, respectively). See the `eachpage` function documentation for more information and performance tips. These iterators do not seek to the beginning of the underlying stream, so if you have already read some pages they will iterate through the _remaining_ pages. More commonly you'll be interested in the packets that can decoded by a codec into the audio or video content.

### `OggPage`

An `OggPage` represents the data from one page of a physical or elementary stream. The following methods allow you to inspect its properties:

* `bos(::OggPage)` - returns `true` if the "BOS" (beginning of stream) flag is set
* `eos(::OggPage)` - returns `true` if the "EOS" (end of stream) flag is set
* `continued(::OggPage)` - returns `true` if the "continued" flag is set
* `granulepos(::OggPage)` - returns the granule position of this page. The precise meaning is codec-dependent, but in general it represents some kind of sample or frame count of the last complete packet contained in this page.
* `serial(::OggPage)` - a 4-byte serial number for this logical stream that is unique within the physical stream
* `sequencenum(::OggPage)` - a page counter. This is useful to detect missing data in the stream
* `checksum(::OggPage)` - The CRC32 checksum of the page, as reported in the header
* `segments(::OggPage)` - Returns a `Vector{Vector{UInt8}}` containing the segments in this page. Segments can be concatenated into a logical stream packet, with all segments being of length 255 except the last, which will be shorter.

### `OggLogicalStream`

An `OggLogicalStream` represents a logical bitstream made up of packets that can be decoded into audio or video. Once you've opened a logical stream, you can iterate through its packets with the `eachpacket(::OggLogicalStream)` method. See the method documentation for details and performance tips. Because we use the standard Julia iterator API, you can get all the packets as a list with `collect(eachpacket(logstream))`.

Each packet is just a `Vector{UInt8}`, and Ogg.jl doesn't know anything about how to interpret them.

When reading from a logical stream with `eachpacket`, the task will yield while reading data from the underlying `IO` object, so when reading from multiple logical streams you'll generally want to read from each stream within a different `@async` block, so the tasks will interleave their handling as the file or stream is read.

All logical streams within an `OggDecoder` must be opened before you start iterating any of them. This is because internally the `OggDecoder` buffers any physical bitstream data that's between the "read heads" of all opened logical streams. Once you start iterating through the streams, any data from unopened streams will be ignored.

## Chained Files

Ogg files can be "chained", where there are multiple collections of logical bitstreams concatenated into a single physical bitstream. These look in effect like multiple full Ogg files concatenated, so when all opened logical streams have ended, you can just open a new `OggDecoder` on the physical stream and decode the new logical streams.

So opening a (possibly chained) Ogg file with two streams and processing their packets would look like:

```julia
open("filename.ogg") do phystream
    while !eof(phystream)
        OggDecoder(phystream) do oggdec
            logstream1 = open(streams(oggdec)[1])
            logstream2 = open(streams(oggdec)[2])
            @sync begin
                @async for packet in eachpacket(logstream1)
                    # handle the packet
                end
                @async for packet in eachpacket(logstream2)
                    # handle the packet
                end
            end
            close(logstream1)
            close(logstream2)
        end
    end
end
```

Alternatively you can use `do` syntax to close the stream automatically, though this adds a level of nesting to ensure that all streams are opened before you start iterating through them:

```julia
open("filename.ogg") do phystream
    while !eof(phystream)
        OggDecoder(phystream) do oggdec
            open(streams(oggdec)[1]) do logstream1
                open(streams(oggdec)[2]) do logstream2
                    @sync
                        @async for packet in eachpacket(logstream1)
                            # handle the packet
                        end
                        @async for packet in eachpacket(logstream2)
                            # handle the packet
                        end
                    end
                end
            end
        end
    end
end
```


## Seeking

Seeking within an Ogg file usually requires higher-level codec knowledge, so while `OggDecoder` supports the usual `seek`/`skip`/`position` API, it just passes the given argument to the underlying `IO` stream. You can then use the `readpage`, `readpacket`, `eachpage`, and `eachpacket` functions as usual and the stream will automatically be synchronized (parsing will start on the next valid page after the seek location).

If there are multiple logical streams opened, seeking will affect all of them, resetting the `OggLogicalStream` objects to point to the same location, and discarding any buffered data. Seeking the underlying `IO` stream directly will fail to synchronize the read heads properly, so it's important to seek the `OggDecoder` instead.

## Resource Management

Both `OggDecoder` and `OggLogicalStream` need to be closed when you are done with them. In both cases you can either call `close` explicitly or use `do` syntax to handle the closing automatically. One important feature is that they are closed in the case of an error. When closing manually make sure to put `close` in a `finally` block, e.g.

```julia
oggdec = OggDecoder("filename.ogg")
try
    # do stuff with oggdec
finally
    close(oggdec)
end
```
