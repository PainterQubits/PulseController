module Qubits

using ..Clifford
import ..Clifford: Idle, Xpi, Xpi2, X3pi2, Ypi, Ypi2, Y3pi2, Zpi, Zpi2, Z3pi2, CZ
using ..Waveforms
using InstrumentControl
import InstrumentControl.Instrument
import InstrumentControl.AWG5014C.InsAWG5014C

export Qubit
export QubitWithZ
export QubitNoZ
export cosInit
export gaussInit
export generalInit

export Readout

# From Clifford
export benchmark1Qubit
export benchmark2Qubit
export Pulse
export gateNames

# From Waveforms
export FloatWaveform
export ExactWaveform
#========================== The Qubit DataType ================================#
# For the purposes of this code, the only info needed about a qubit is its
# resonant frequency relative to the local oscillator, which boards/lines
# are able to communicate with it, and the on-board data for gates.

# Depending on if lines permit, we can control our qubits with only XY control
# or with full XYZ.  If the Z line is absent, the underlying type is a QubitNoZ,
# and if present it is a QubitWithZ.  The user only creates "Qubit" objects,
# and depending on whether a Z line is specified, the program generates the
# proper concrete type.

abstract Qubit

type QubitWithZ <: Qubit
  IFreq::Float64
  lineXYI::Tuple{Instrument,Int} # (board, channel)
  lineXYQ::Tuple{Instrument,Int} #  "
  lineZ::Tuple{Instrument,Int}   #  "
  pulseConvert::Matrix        # 10x3 matrix, which maps the 10 basic pulses
                              # to how the DAC's memory refers to them

  waveforms::Dict{Pulse, ExactWaveform} # See below.
end

type QubitNoZ <: Qubit
  IFreq::Float64
  lineXYI::Tuple{Instrument,Int} # (board, channel)
  lineXYQ::Tuple{Instrument,Int} #  "
  pulseConvert::Matrix        # 7x2 mapping basic pulses to XYI and XYQ labels
                              # in the DAC's memory (for AWG, this is strings,
                              # for reasons that only frustrate me..)

  waveforms::Dict{Pulse, ExactWaveform} # See below.
end

# Accessing a qubit as a dictionary will alter the contained dictionary of
# pulses.  Though the dictionary itself only contains ExactWaveform values,
# the methods below provide ways to convert FloatWaveform and Vector{Float64}
# values to ExactWaveform.  An explicit convert method cannot be written, since
# the ExactWaveform produced depends on the Pulse and on the IFreq of the qubit.
import Base.setindex!
import InstrumentControl.AWG5014C: offsetValue
function setindex!(q::Qubit, w::Vector{Float64}, p::Pulse)
  if p in keys(q.waveforms)
    undef = q.waveforms[p].undefined
  else
    undef = true
  end
  if p[1] == 7
    q.waveforms[p] = ExactWaveform(UInt16[], UInt16[], UInt16[], undef, true)
  elseif length(w) != floatIdleLength
      error("FloatWaveform pulses must contain exactly "*
                                 string(floatIdleLength)*" points")
  elseif p[1] < 7
    (xyi, xyq) = IQgen(q.IFreq, p, w)
    q.waveforms[p] = ExactWaveform(xyi, xyq, UInt16[], undef, true)
  elseif p[1] < 11 && isa(q, QubitWithZ)
    q.waveforms[p] = ExactWaveform(UInt16[], UInt16[],
                    map(x -> UInt16(offsetValue + round(x)), w), undef, true)
  else # Trying to set Z gates on a QubitNoZ object
    println("Warning: no gates set by this operation.")
  end
end

# A helper method for the above that uses the IFreq and the intended phase to
# determine the I and Q pulses.
function IQgen(IFreq::Float64, pulse::Pulse, window::Vector{Float64})
  if pulse[1] > 6
    error("Not a pulse in need of IQ mixing")
  else
    phase = im ^ pulse[1]
    helix = phase * [exp(im * 2π * IFreq * p / 1e9) * window[p]
                                  for p in 1:length(window)]
    waveformI = map(z->UInt16(offsetValue + round(real(z))), helix)
    waveformQ = map(z->UInt16(offsetValue + round(imag(z))), helix)
    waveformI, waveformQ
  end
end

# For FloatWaveforms, use the contained wavedata field.
function setindex!(q::Qubit, w::FloatWaveform, p::Pulse)
  setindex!(q, w.wavedata, p)
end

# For ExactWaveforms, use them as they are.
function setindex!(q::Qubit, w::ExactWaveform, p::Pulse)
  if p[1] < 7 || isa(QubitWithZ)
    w.dirty = true
    q.waveforms[p] = w
  else # Trying to set Z gates on a QubitNoZ object
    println("Warning: no gates set by this operation.")
  end
end

# Always display the ExactWaveform for the user to see.
import Base.getindex
function getindex(q::Qubit, p::Pulse)
  return q.waveforms[p]
end

# ================= Initializing a Qubit's information ========================#

# A user shouldn't have to specify the matrix or the dictionary to define a
# qubit.  All that they should have to input is IFreq and the line info.

function Qubit(IFreq::Float64, lineXYI::Tuple{Instrument,Int},
        lineXYQ::Tuple{Instrument,Int})
    if (isa(lineXYI[1], InsAWG5014C) || isa(lineXYQ[1], InsAWG5014C)) && (IFreq % 4e6 != 0)
      println("WARNING: given IFreq will cause inconsistent phase within "*
              "consecutive 250ns pulses")
    end
    ret = QubitNoZ(IFreq, lineXYI, lineXYQ, fill("-1", (7,2)), Dict())
    println("To initialize pulse shapes for this Qubit, please run one of the "*
           "init routines:\n\tgaussInit\n\tcosInit\n\tgeneralInit")
    ret
end

function Qubit(IFreq::Float64, lineXYI::Tuple{Instrument,Int},
    lineXYQ::Tuple{Instrument,Int}, lineZ::Tuple{Instrument,Int})

    if (isa(lineXYI[1], InsAWG5014C) || isa(lineXYQ[1], InsAWG5014C) ||
        isa(lineZ[1], InsAWG5014C)) && (IFreq % (1e9/AWGLENGTH) != 0)
      println("WARNING: given IFreq will cause inconsistent phase within "*
              "consecutive 250ns pulses")
    end
    ret = QubitWithZ(IFreq, lineXYI, lineXYQ, lineZ, fill("-1", (10,3)), Dict())
    println("To initialize pulse shapes for this Qubit, please run one of the "*
            "init routines:\n\tgaussInit\n\tcosInit\n\tgeneralInit")
    ret
end

# Initializing the dictionary shouldn't require manually inputting up to 10
# different pulse shapes, so we provide quick ways to make gaussian-envelope and
# cos-envelope pulses.  These are all FloatWaveform objects with all the
# assumptions mentioned above.  We also provide a generalInit function that
# takes a shape for the window, though it must be floatIdleLength points exactly
# or an error will be thrown down the line.

# These functions assume that half-amplitude pulses provide half the rotation.
# This is a good starting point but is not accurate for high-fidelity gates.

# The XY and Z arguments specify whether the pulses created are for the XY
# control or the Z control.  By default, both are on, but it is likely the
# ideal amplitude for each is different.  For QubitNoZ objects, setting Z to
# true or false makes no difference.
function gaussInit(q::Qubit, amplitude, sigma, XY::Bool = true, Z::Bool = true)
  pulseShape = [amplitude*exp(-(x - (floatIdleLength + 1)/2)^2 / (2*sigma^2))
                                for x in 1:floatIdleLength]
  pulseShape -= pulseShape[1] # To eliminate the tails
  generalInit(q, pulseShape, XY, Z)
end

function cosInit(q::Qubit, amplitude, XY::Bool = true, Z::Bool = true)
  pulseShape = [amplitude*(1-cos(2π*x/floatIdleLength))/2
                                for x in 1:floatIdleLength]
  generalInit(q, pulseShape, XY, Z)
end

function generalInit(q::Qubit, pulseShape, XY::Bool = true, Z::Bool = true)
  if XY
    q[Xpi] = q[Ypi] = pulseShape
    q[Xpi2] = q[Ypi2] = q[X3pi2] = q[Y3pi2] = pulseShape/2
  end
  if Z && isa(q, QubitWithZ)
    q[Zpi] = pulseShape
    q[Zpi2] = pulseShape/2
    q[Z3pi2] = -pulseShape/2
  end
  if q.pulseConvert[7] == "-1"
    q[Idle] = [0.0 for _ in 1:floatIdleLength]
  end
  return "Initialization successful"
end

# We also define a Readout object similar to the Qubit object, which makes
# the sequencing a bit cleaner.  It holds just the readout pulse, which
# consists of a rectangle windowed IF tone and a long wait.
type Readout
  lineXYI::Tuple{Instrument,Int}
  lineXYQ::Tuple{Instrument,Int}
  ROWaveform::ExactWaveform
  ROIdle::ExactWaveform
end

# Given a window length in samples, and an optional delay length in samples,
# construct the readout pulse.
function Readout(IFreq, lineXYI::Tuple{Instrument,Int},
                        lineXYQ::Tuple{Instrument,Int},
                        window::Int, delay=100000)
  roi, roq = IQgen(IFreq, Xpi, [fill(8191, window); zeros(delay)])
  # Set markers for readout
  roi[1:100] |= 0xc000
  roq[1:100] |= 0xc000
  RO = ExactWaveform(roi, roq, UInt16[], true, true)
  ROIdle = ExactWaveform(fill(offsetValue, window+delay), UInt16[], UInt16[], true, true)
  Readout(lineXYI, lineXYQ, RO, ROIdle)
end

end # End module Qubit
