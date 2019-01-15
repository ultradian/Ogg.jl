__precompile__()
module Ogg

# using FileIO
# import Base: show, convert
# export OggDecoder, OggEncoder, OggPage
# export serial, eos, bos
# export eachpage
export OggEncoder
export save
export OggDecoder, OggLogicalStream, OggPage
export streams, eachpage, readpage, lastpage, seekgranule
export serial, bos, eos
export OggPacket
export readpacket, eachpacket, packetno, granulepos

const depfile = joinpath(@__DIR__, "..", "deps", "deps.jl")
if isfile(depfile)
    include(depfile)
else
    error("libogg not properly installed. Please run Pkg.build(\"Ogg\")")
end

# in almost every part of the API serial numbers are represented as ints.
const SerialNum = Cint

include("libogg.jl")
include("decoder.jl")
include("encoder.jl")

end # module
