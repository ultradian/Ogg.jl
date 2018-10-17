using Ogg
using Test

@testset "Ogg.jl Tests" begin

@testset "Ogg synthesis/analysis" begin
    # Let's start with building our own Ogg structure, writing it out to an IOBuf,
    # then loading it back in again and checking everything about it we can think of

    # We are going to build three streams, each with 10 packets
    num_packets = 10
    stream_ids = Cint[1, 2, 3]
    packets = Dict{Clong,Vector{Vector{UInt8}}}()
    granulepos = Dict{Int64,Vector{Int64}}()
    for serial in stream_ids
        # The packets are all of different size (100, 200, 300, ... 1000)
        # the content of each packet is just incrementing bytes
        packets[serial] = Vector{UInt8}[UInt8.(mod.(collect(1:100*x), 256)) for x in 1:num_packets]

        # Each packet will have a monotonically increasing granulepos, except for
        # the first two packets which are our "header" packets with granulepos == 0
        granulepos[serial] = Int64[0, 0, [20*x for x in 1:(num_packets - 2)]...]
    end

    # Now we write these packets out to an IOBuffer
    ogg_file = IOBuffer()
    save(ogg_file, packets, granulepos)

    # Rewind to the beginning of this IOBuffer and load the packets back in
    seekstart(ogg_file)
    pages = Dict{Int, Vector{OggPage}}()

    # the streams are chained together serially, so just decode the right number
    # of links
    # TODO: currently we only go through the first link in the chain. There's
    # a problem where the OggDecoder grabs too much data at the end of the link
    # and so the next link doesn't start at the very beginning. Fixing this will
    # require some architecture and API changes - I think we'll want to have a
    # single OggDecoder span all the links, so it can use the extra data it grabs
    # after one link to start the next one.
    for _ in stream_ids[1:1]
        OggDecoder(ogg_file) do oggdec
            strs = streams(oggdec)
            @test length(strs) == 1
            serialnum = strs[1]
            @test serialnum in stream_ids

            open(oggdec, serialnum) do logstream
                pages[serialnum] = collect(eachpage(logstream))
            end
        end
    end
    @test eof(ogg_file)

    for serialnum in keys(pages)
        @test all(serial.(pages[serialnum]) .== serialnum)
        page = pages[serialnum][1]

        # Let's dig deeper; let's ensure that the first two pages had length equal to
        # our first two packets, proving that our header packets had their own pages:
        @test page.page.body_len == length(packets[serialnum][1])
        page = pages[serialnum][2]
        @test page.page.body_len == length(packets[serialnum][2])
    end


    # # Are the number of packets the same?
    # for serial in stream_ids
    #     @test length(dec.packets[serial]) == length(packets[serial])
    # end
    #
    # # Are the contents of the packets the same?
    # for serial in stream_ids
    #     for packet_idx in 1:length(dec.packets[serial])
    #         @test dec.packets[serial][packet_idx] == packets[serial][packet_idx]
    #     end
    # end

end


# Next, let's load a known ogg stream and ensure that it's exactly as we expect
@testset "Known .ogg decoding" begin
    OggDecoder(joinpath(@__DIR__, "zero.ogg")) do dec
        page = readpage(dec)
        @test page isa OggPage
        # There is only one stream, and we know its serial number
        @test serial(page) == 1238561138
        @test bos(page)
        @test !eos(page)

        page = readpage(dec)
        @test !bos(page)
        @test !eos(page)
        page = readpage(dec)
        @test !bos(page)
        @test eos(page)
        page = readpage(dec)
        @test page === nothing
    end

    OggDecoder(joinpath(@__DIR__, "zero.ogg")) do dec
        pages = collect(eachpage(dec))
        @test length(pages) == 3
        @test eltype(pages) == OggPage
        @test all(serial.(pages) .== 1238561138)
    end

    OggDecoder(joinpath(@__DIR__, "zero.ogg")) do dec
        strs = streams(dec)
        @test length(strs) == 1
        @test eltype(strs) == Cint
        @test strs[1] == 1238561138
    end

    # # There are four packets, the first starts with \x7fFLAC
    # @test length(ogg_packets[serial]) == 4
    # @test String(copy(ogg_packets[serial][1][2:5])) == "FLAC"
    #
    # # The lengths of the packets are:
    # @test [length(x) for x in ogg_packets[serial]] == [51, 55, 13, 0]
end

@testset "More complicated Ogg reading" begin
    fname = joinpath(@__DIR__, "test.ogv")
    isfile(fname) || download("https://upload.wikimedia.org/wikipedia/commons/a/a4/Xacti-AC8EX-Sample_video-001.ogv",
                              fname)
    OggDecoder(fname) do dec
        strs = streams(dec)
        @test length(strs) == 2
        @test strs[1] == 1652356087
        @test strs[2] == 1901308512
    end

    # make sure that the pages all get read in regardless of the order we
    # read them - this tests that the buffering is working correctly
    local str1_pages1
    local str1_pages2
    local str2_pages1
    local str2_pages2
    OggDecoder(fname) do dec
        strs = streams(dec)
        open(dec, strs[1]) do str1
            open(dec, strs[2]) do str2
                str1_pages1 = collect(eachpage(str1))
                str2_pages1 = collect(eachpage(str2))
            end
        end
    end
    OggDecoder(fname) do dec
        strs = streams(dec)
        open(dec, strs[1]) do str1
            open(dec, strs[2]) do str2
                str2_pages2 = collect(eachpage(str2))
                str1_pages2 = collect(eachpage(str1))
            end
        end
    end
    @test str1_pages1[1] == str1_pages2[1]
    @test str2_pages1[1] == str2_pages2[1]
end

@testset "OggPage Copying" begin
    rawheader = UInt8.(1:10)
    rawbody = UInt8.(1:20)
    rawpage = Ogg.RawOggPage(pointer(rawheader), 10, pointer(rawbody), 20)

    nocopypage = OggPage(rawpage; copy=false)
    @test nocopypage.headerbuf === nothing
    @test nocopypage.bodybuf === nothing
    @test nocopypage.page == rawpage

    copypage = OggPage(rawpage)
    @test copypage.page.header != pointer(rawheader)
    @test copypage.page.body != pointer(rawbody)
    @test copypage.page.header == pointer(copypage.headerbuf)
    @test copypage.page.body == pointer(copypage.bodybuf)
    @test unsafe_wrap(Array, copypage.page.header, 10) == rawheader
    @test unsafe_wrap(Array, copypage.page.body, 20) == rawbody
    @test copypage.page.header_len == 10
    @test copypage.page.body_len == 20

    # make sure deepcopy works whether or not the source has its own data
    deepcopypage = deepcopy(nocopypage)
    @test deepcopypage.page.header != pointer(rawheader)
    @test deepcopypage.page.body != pointer(rawbody)
    @test deepcopypage.page.header == pointer(deepcopypage.headerbuf)
    @test deepcopypage.page.body == pointer(deepcopypage.bodybuf)
    @test unsafe_wrap(Array, deepcopypage.page.header, 10) == rawheader
    @test unsafe_wrap(Array, deepcopypage.page.body, 20) == rawbody
    @test deepcopypage.page.header_len == 10
    @test deepcopypage.page.body_len == 20

    deepcopypage = deepcopy(copypage)
    @test deepcopypage.page.header != pointer(copypage.headerbuf)
    @test deepcopypage.page.body != pointer(copypage.bodybuf)
    @test deepcopypage.page.header == pointer(deepcopypage.headerbuf)
    @test deepcopypage.page.body == pointer(deepcopypage.bodybuf)
    @test unsafe_wrap(Array, deepcopypage.page.header, 10) == rawheader
    @test unsafe_wrap(Array, deepcopypage.page.body, 20) == rawbody
    @test deepcopypage.page.header_len == 10
    @test deepcopypage.page.body_len == 20
end

end # @testset
