use core::traits::TryInto;
use core::traits::Into;
use orion::operators::tensor::{Tensor, U32Tensor,};
use orion::numbers::FP32x32;
use core::option::OptionTrait;
use koji::midi::types::{
    Midi, Message, Modes, ArpPattern, VelocityCurve, NoteOn, NoteOff, SetTempo, TimeSignature,
    ControlChange, PitchWheel, AfterTouch, PolyTouch, Direction, PitchClass, ProgramChange,
    SystemExclusive,
};
use alexandria_data_structures::stack::{StackTrait, Felt252Stack, NullableStack};
use alexandria_data_structures::array_ext::{ArrayTraitExt, SpanTraitExt};

use koji::midi::instruments::{
    GeneralMidiInstrument, instrument_name, instrument_to_program_change,
    program_change_to_instrument, next_instrument_in_group
};
use koji::midi::time::round_to_nearest_nth;
use koji::midi::modes::{mode_steps};
use koji::midi::pitch::{PitchClassTrait, keynum_to_pc};
use koji::midi::velocitycurve::{VelocityCurveTrait};

trait MidiTrait {
    /// =========== NOTE MANIPULATION ===========
    /// Instantiate a Midi.
    fn new() -> Midi;
    /// Append a message in a Midi object.
    fn append_message(self: @Midi, msg: Message) -> Midi;
    /// Transpose notes by a given number of semitones.
    fn transpose_notes(self: @Midi, semitones: i32) -> Midi;
    ///  Reverse the order of notes.
    fn reverse_notes(self: @Midi) -> Midi;
    /// Align notes to a given rhythmic grid.
    fn quantize_notes(self: @Midi, grid_size: usize) -> Midi;
    /// Extract notes within a specified pitch range.
    fn extract_notes(self: @Midi, note_range: usize) -> Midi;
    /// Change the duration of notes by a given factor
    fn change_note_duration(self: @Midi, factor: i32) -> Midi;
    /// =========== GLOBAL MANIPULATION ===========
    /// Alter the tempo of the Midi data.
    fn change_tempo(self: @Midi, new_tempo: u32) -> Midi;
    /// Change instrument patches based on a provided mapping
    fn remap_instruments(self: @Midi, chanel: u32) -> Midi;
    /// =========== ANALYSIS ===========
    /// Extract the tempo (in BPM) from the Midi data.
    fn get_bpm(self: @Midi) -> u32;
    /// Return statistics about notes (e.g., most frequent note, average note duration).
    /// =========== ADVANCED MANIPULATION ===========
    /// Add harmonies to existing melodies based on specified intervals.
    fn generate_harmony(self: @Midi, steps: i32, tonic: PitchClass, modes: Modes) -> Midi;
    /// Convert chords into arpeggios based on a given pattern.
    fn arpeggiate_chords(self: @Midi, pattern: ArpPattern) -> Midi;
    /// Add or modify dynamics (velocity) of notes based on a specified curve or pattern.
    fn edit_dynamics(self: @Midi, curve: VelocityCurve) -> Midi;
    // Cairo function that converts a Midi struct to a ByteArray representing a MIDI file
    fn midi_to_bytearray(self: @Midi) -> ByteArray;
}

impl MidiImpl of MidiTrait {
    fn new() -> Midi {
        Midi { events: array![].span() }
    }

    fn append_message(self: @Midi, msg: Message) -> Midi {
        let mut ev = *self.events;
        let mut output = array![];

        loop {
            match ev.pop_front() {
                Option::Some(currentevent) => { output.append(*currentevent); },
                Option::None(_) => { break; },
            };
        };

        output.append(msg);
        Midi { events: output.span() }
    }

    fn transpose_notes(self: @Midi, semitones: i32) -> Midi {
        let mut ev = self.clone().events;
        let mut eventlist = ArrayTrait::<Message>::new();

        loop {
            match ev.pop_front() {
                Option::Some(currentevent) => {
                    match currentevent {
                        Message::NOTE_ON(NoteOn) => {
                            let outnote = if semitones < 0 {
                                *NoteOn.note - semitones.try_into().unwrap()
                            } else {
                                *NoteOn.note + semitones.try_into().unwrap()
                            };
                            let newnote = NoteOn {
                                channel: *NoteOn.channel,
                                note: outnote,
                                velocity: *NoteOn.velocity,
                                time: *NoteOn.time
                            };
                            let notemessage = Message::NOTE_ON((newnote));
                            eventlist.append(notemessage);
                        },
                        Message::NOTE_OFF(NoteOff) => {
                            let outnote = if semitones < 0 {
                                *NoteOff.note - semitones.try_into().unwrap()
                            } else {
                                *NoteOff.note + semitones.try_into().unwrap()
                            };

                            let newnote = NoteOff {
                                channel: *NoteOff.channel,
                                note: outnote,
                                velocity: *NoteOff.velocity,
                                time: *NoteOff.time
                            };
                            let notemessage = Message::NOTE_OFF((newnote));
                            eventlist.append(notemessage);
                        },
                        Message::SET_TEMPO(_SetTempo) => { eventlist.append(*currentevent); },
                        Message::TIME_SIGNATURE(_TimeSignature) => {
                            eventlist.append(*currentevent);
                        },
                        Message::CONTROL_CHANGE(_ControlChange) => {
                            eventlist.append(*currentevent);
                        },
                        Message::PITCH_WHEEL(_PitchWheel) => { eventlist.append(*currentevent); },
                        Message::AFTER_TOUCH(_AfterTouch) => { eventlist.append(*currentevent); },
                        Message::POLY_TOUCH(_PolyTouch) => { eventlist.append(*currentevent); },
                        Message::PROGRAM_CHANGE(_ProgramChange) => {
                            eventlist.append(*currentevent);
                        },
                        Message::SYSTEM_EXCLUSIVE(_SystemExclusive) => {
                            eventlist.append(*currentevent);
                        },
                    }
                },
                Option::None(_) => { break; }
            };
        };

        Midi { events: eventlist.span() }
    }

    fn reverse_notes(self: @Midi) -> Midi {
        let mut ev = self.clone().events;
        let mut rev = self.clone().events.reverse().span();
        let lastmsgtime = rev.pop_front();
        let firstmsgtime = ev.pop_front();
        let mut maxtime = FP32x32 { mag: 0, sign: false };
        let mut mintime = FP32x32 { mag: 0, sign: false };
        let mut eventlist = ArrayTrait::<Message>::new();

        //assign maxtime to the last message's time value in the Midi
        match lastmsgtime {
            Option::Some(currentev) => {
                match currentev {
                    Message::NOTE_ON(NoteOn) => { maxtime = *NoteOn.time; },
                    Message::NOTE_OFF(NoteOff) => { maxtime = *NoteOff.time; },
                    Message::SET_TEMPO(SetTempo) => {
                        match *SetTempo.time {
                            Option::Some(time) => { maxtime = time; },
                            Option::None => {},
                        }
                    },
                    Message::TIME_SIGNATURE(TimeSignature) => {
                        match *TimeSignature.time {
                            Option::Some(time) => { maxtime = time; },
                            Option::None => {},
                        }
                    },
                    Message::CONTROL_CHANGE(ControlChange) => { maxtime = *ControlChange.time; },
                    Message::PITCH_WHEEL(PitchWheel) => { maxtime = *PitchWheel.time; },
                    Message::AFTER_TOUCH(AfterTouch) => { maxtime = *AfterTouch.time; },
                    Message::POLY_TOUCH(PolyTouch) => { maxtime = *PolyTouch.time; },
                    Message::PROGRAM_CHANGE(ProgramChange) => { maxtime = *ProgramChange.time; },
                    Message::SYSTEM_EXCLUSIVE(SystemExclusive) => {
                        maxtime = *SystemExclusive.time;
                    },
                }
            },
            Option::None(_) => {}
        };

        //assign mintime to the first message's time value
        match firstmsgtime {
            Option::Some(currentev) => {
                match currentev {
                    Message::NOTE_ON(NoteOn) => { mintime = *NoteOn.time; },
                    Message::NOTE_OFF(NoteOff) => { mintime = *NoteOff.time; },
                    Message::SET_TEMPO(SetTempo) => {
                        match *SetTempo.time {
                            Option::Some(time) => { mintime = time; },
                            Option::None => {},
                        }
                    },
                    Message::TIME_SIGNATURE(TimeSignature) => {
                        match *TimeSignature.time {
                            Option::Some(time) => { mintime = time; },
                            Option::None => {},
                        }
                    },
                    Message::CONTROL_CHANGE(ControlChange) => { mintime = *ControlChange.time; },
                    Message::PITCH_WHEEL(PitchWheel) => { mintime = *PitchWheel.time; },
                    Message::AFTER_TOUCH(AfterTouch) => { mintime = *AfterTouch.time; },
                    Message::POLY_TOUCH(PolyTouch) => { mintime = *PolyTouch.time; },
                    Message::PROGRAM_CHANGE(ProgramChange) => { mintime = *ProgramChange.time; },
                    Message::SYSTEM_EXCLUSIVE(SystemExclusive) => {
                        mintime = *SystemExclusive.time;
                    },
                }
            },
            Option::None(_) => {}
        };

        loop {
            match rev.pop_front() {
                Option::Some(currentevent) => {
                    match currentevent {
                        Message::NOTE_ON(NoteOn) => {
                            let newnote = NoteOff {
                                channel: *NoteOn.channel,
                                note: *NoteOn.note,
                                velocity: *NoteOn.velocity,
                                time: ((maxtime - *NoteOn.time) + mintime)
                            };
                            let notemessage = Message::NOTE_OFF((newnote));
                            eventlist.append(notemessage);
                        },
                        Message::NOTE_OFF(NoteOff) => {
                            let newnote = NoteOn {
                                channel: *NoteOff.channel,
                                note: *NoteOff.note,
                                velocity: *NoteOff.velocity,
                                time: (maxtime - *NoteOff.time) + mintime
                            };
                            let notemessage = Message::NOTE_ON((newnote));
                            eventlist.append(notemessage);
                        },
                        Message::SET_TEMPO(SetTempo) => {
                            let scaledtempo = SetTempo {
                                tempo: *SetTempo.tempo,
                                time: match *SetTempo.time {
                                    Option::Some(time) => Option::Some((maxtime - time) + mintime),
                                    Option::None => Option::None,
                                }
                            };
                            let tempomessage = Message::SET_TEMPO((scaledtempo));
                            eventlist.append(tempomessage);
                        },
                        Message::TIME_SIGNATURE(TimeSignature) => {
                            let newtimesig = TimeSignature {
                                numerator: *TimeSignature.numerator,
                                denominator: *TimeSignature.denominator,
                                clocks_per_click: *TimeSignature.clocks_per_click,
                                time: match *TimeSignature.time {
                                    Option::Some(time) => Option::Some((maxtime - time) + mintime),
                                    Option::None => Option::None,
                                }
                            };
                            let tsmessage = Message::TIME_SIGNATURE((newtimesig));
                            eventlist.append(tsmessage);
                        },
                        Message::CONTROL_CHANGE(ControlChange) => {
                            let newcontrolchange = ControlChange {
                                channel: *ControlChange.channel,
                                control: *ControlChange.control,
                                value: *ControlChange.value,
                                time: (maxtime - *ControlChange.time) + mintime
                            };
                            let ccmessage = Message::CONTROL_CHANGE((newcontrolchange));
                            eventlist.append(ccmessage);
                        },
                        Message::PITCH_WHEEL(PitchWheel) => {
                            let newpitchwheel = PitchWheel {
                                channel: *PitchWheel.channel,
                                pitch: *PitchWheel.pitch,
                                time: (maxtime - *PitchWheel.time) + mintime
                            };
                            let pwmessage = Message::PITCH_WHEEL((newpitchwheel));
                            eventlist.append(pwmessage);
                        },
                        Message::AFTER_TOUCH(AfterTouch) => {
                            let newaftertouch = AfterTouch {
                                channel: *AfterTouch.channel,
                                value: *AfterTouch.value,
                                time: (maxtime - *AfterTouch.time) + mintime
                            };
                            let atmessage = Message::AFTER_TOUCH((newaftertouch));
                            eventlist.append(atmessage);
                        },
                        Message::POLY_TOUCH(PolyTouch) => {
                            let newpolytouch = PolyTouch {
                                channel: *PolyTouch.channel,
                                note: *PolyTouch.note,
                                value: *PolyTouch.value,
                                time: (maxtime - *PolyTouch.time) + mintime
                            };
                            let ptmessage = Message::POLY_TOUCH((newpolytouch));
                            eventlist.append(ptmessage);
                        },
                        Message::PROGRAM_CHANGE(ProgramChange) => {
                            let newprogchg = ProgramChange {
                                channel: *ProgramChange.channel,
                                program: *ProgramChange.program,
                                time: (maxtime - *ProgramChange.time) + mintime
                            };
                            let pchgmessage = Message::PROGRAM_CHANGE((newprogchg));
                            eventlist.append(pchgmessage);
                        },
                        Message::SYSTEM_EXCLUSIVE(SystemExclusive) => {
                            let newsysex = SystemExclusive {
                                manufacturer_id: *SystemExclusive.manufacturer_id,
                                device_id: *SystemExclusive.device_id,
                                data: *SystemExclusive.data,
                                checksum: *SystemExclusive.checksum,
                                time: (maxtime - *SystemExclusive.time) + mintime
                            };
                            let sysexgmessage = Message::SYSTEM_EXCLUSIVE((newsysex));
                            eventlist.append(sysexgmessage);
                        },
                    }
                },
                Option::None(_) => { break; }
            };
        };

        Midi { events: eventlist.span() }
    }

    fn quantize_notes(self: @Midi, grid_size: usize) -> Midi {
        let mut ev = self.clone().events;
        let mut eventlist = ArrayTrait::<Message>::new();

        loop {
            match ev.pop_front() {
                Option::Some(currentevent) => {
                    match currentevent {
                        Message::NOTE_ON(NoteOn) => {
                            let newnote = NoteOn {
                                channel: *NoteOn.channel,
                                note: *NoteOn.note,
                                velocity: *NoteOn.velocity,
                                time: round_to_nearest_nth(*NoteOn.time, grid_size)
                            };
                            let notemessage = Message::NOTE_ON((newnote));
                            eventlist.append(notemessage);
                        },
                        Message::NOTE_OFF(NoteOff) => {
                            let newnote = NoteOff {
                                channel: *NoteOff.channel,
                                note: *NoteOff.note,
                                velocity: *NoteOff.velocity,
                                time: round_to_nearest_nth(*NoteOff.time, grid_size)
                            };
                            let notemessage = Message::NOTE_OFF((newnote));
                            eventlist.append(notemessage);
                        },
                        Message::SET_TEMPO(_SetTempo) => { eventlist.append(*currentevent) },
                        Message::TIME_SIGNATURE(_TimeSignature) => {
                            eventlist.append(*currentevent)
                        },
                        Message::CONTROL_CHANGE(_ControlChange) => {
                            eventlist.append(*currentevent)
                        },
                        Message::PITCH_WHEEL(_PitchWheel) => { eventlist.append(*currentevent) },
                        Message::AFTER_TOUCH(_AfterTouch) => { eventlist.append(*currentevent) },
                        Message::POLY_TOUCH(_PolyTouch) => { eventlist.append(*currentevent) },
                        Message::PROGRAM_CHANGE(_ProgramChange) => {
                            eventlist.append(*currentevent)
                        },
                        Message::SYSTEM_EXCLUSIVE(_SystemExclusive) => {
                            eventlist.append(*currentevent);
                        },
                    }
                },
                Option::None(_) => { break; }
            };
        };

        // Create a new Midi object with the modified event list
        Midi { events: eventlist.span() }
    }

    fn extract_notes(self: @Midi, note_range: usize) -> Midi {
        let mut ev = self.clone().events;

        let middlec = 60;
        let mut lowerbound = 0;
        let mut upperbound = 127;

        if note_range < middlec {
            lowerbound = middlec - note_range;
        }
        if note_range + middlec < 127 {
            upperbound = middlec + note_range;
        }

        let mut eventlist = ArrayTrait::<Message>::new();

        loop {
            match ev.pop_front() {
                Option::Some(currentevent) => {
                    match currentevent {
                        Message::NOTE_ON(NoteOn) => {
                            let currentnoteon = *NoteOn.note;
                            if currentnoteon > lowerbound.try_into().unwrap()
                                && currentnoteon < upperbound.try_into().unwrap() {
                                eventlist.append(*currentevent);
                            }
                        },
                        Message::NOTE_OFF(NoteOff) => {
                            let currentnoteoff = *NoteOff.note;
                            if currentnoteoff > lowerbound.try_into().unwrap()
                                && currentnoteoff < upperbound.try_into().unwrap() {
                                eventlist.append(*currentevent);
                            }
                        },
                        Message::SET_TEMPO(_SetTempo) => {},
                        Message::TIME_SIGNATURE(_TimeSignature) => {},
                        Message::CONTROL_CHANGE(_ControlChange) => {},
                        Message::PITCH_WHEEL(_PitchWheel) => {},
                        Message::AFTER_TOUCH(_AfterTouch) => {},
                        Message::POLY_TOUCH(_PolyTouch) => {},
                        Message::PROGRAM_CHANGE(_ProgramChange) => {},
                        Message::SYSTEM_EXCLUSIVE(_SystemExclusive) => {},
                    }
                },
                Option::None(_) => { break; }
            };
        };

        // Create a new Midi object with the modified event list
        Midi { events: eventlist.span() }
    }


    fn change_note_duration(self: @Midi, factor: i32) -> Midi {
        let newfactor = FP32x32 { mag: factor.try_into().unwrap(), sign: (factor < 0) };
        let mut ev = self.clone().events;
        let mut eventlist = ArrayTrait::<Message>::new();

        loop {
            match ev.pop_front() {
                Option::Some(currentevent) => {
                    match currentevent {
                        Message::NOTE_ON(NoteOn) => {
                            let newnote = NoteOn {
                                channel: *NoteOn.channel,
                                note: *NoteOn.note,
                                velocity: *NoteOn.velocity,
                                time: *NoteOn.time * newfactor
                            };
                            let notemessage = Message::NOTE_ON((newnote));
                            eventlist.append(notemessage);
                        },
                        Message::NOTE_OFF(NoteOff) => {
                            let newnote = NoteOff {
                                channel: *NoteOff.channel,
                                note: *NoteOff.note,
                                velocity: *NoteOff.velocity,
                                time: *NoteOff.time * newfactor
                            };
                            let notemessage = Message::NOTE_OFF((newnote));
                            eventlist.append(notemessage);
                        },
                        Message::SET_TEMPO(SetTempo) => {
                            let scaledtempo = SetTempo {
                                tempo: *SetTempo.tempo,
                                time: match *SetTempo.time {
                                    Option::Some(time) => Option::Some(time * newfactor),
                                    Option::None => Option::None,
                                }
                            };
                            let tempomessage = Message::SET_TEMPO((scaledtempo));
                            eventlist.append(tempomessage);
                        },
                        Message::TIME_SIGNATURE(TimeSignature) => {
                            let newtimesig = TimeSignature {
                                numerator: *TimeSignature.numerator,
                                denominator: *TimeSignature.denominator,
                                clocks_per_click: *TimeSignature.clocks_per_click,
                                time: match *TimeSignature.time {
                                    Option::Some(time) => Option::Some(time * newfactor),
                                    Option::None => Option::None,
                                }
                            };
                            let tsmessage = Message::TIME_SIGNATURE((newtimesig));
                            eventlist.append(tsmessage);
                        },
                        Message::CONTROL_CHANGE(ControlChange) => {
                            let newcontrolchange = ControlChange {
                                channel: *ControlChange.channel,
                                control: *ControlChange.control,
                                value: *ControlChange.value,
                                time: *ControlChange.time * newfactor
                            };
                            let ccmessage = Message::CONTROL_CHANGE((newcontrolchange));
                            eventlist.append(ccmessage);
                        },
                        Message::PITCH_WHEEL(PitchWheel) => {
                            let newpitchwheel = PitchWheel {
                                channel: *PitchWheel.channel,
                                pitch: *PitchWheel.pitch,
                                time: *PitchWheel.time * newfactor
                            };
                            let pwmessage = Message::PITCH_WHEEL((newpitchwheel));
                            eventlist.append(pwmessage);
                        },
                        Message::AFTER_TOUCH(AfterTouch) => {
                            let newaftertouch = AfterTouch {
                                channel: *AfterTouch.channel,
                                value: *AfterTouch.value,
                                time: *AfterTouch.time * newfactor
                            };
                            let atmessage = Message::AFTER_TOUCH((newaftertouch));
                            eventlist.append(atmessage);
                        },
                        Message::POLY_TOUCH(PolyTouch) => {
                            let newpolytouch = PolyTouch {
                                channel: *PolyTouch.channel,
                                note: *PolyTouch.note,
                                value: *PolyTouch.value,
                                time: *PolyTouch.time * newfactor
                            };
                            let ptmessage = Message::POLY_TOUCH((newpolytouch));
                            eventlist.append(ptmessage);
                        },
                        Message::PROGRAM_CHANGE(ProgramChange) => {
                            let newprogchg = ProgramChange {
                                channel: *ProgramChange.channel,
                                program: *ProgramChange.program,
                                time: *ProgramChange.time * newfactor
                            };
                            let pchgmessage = Message::PROGRAM_CHANGE((newprogchg));
                            eventlist.append(pchgmessage);
                        },
                        Message::SYSTEM_EXCLUSIVE(SystemExclusive) => {
                            let newsysex = SystemExclusive {
                                manufacturer_id: *SystemExclusive.manufacturer_id,
                                device_id: *SystemExclusive.device_id,
                                data: *SystemExclusive.data,
                                checksum: *SystemExclusive.checksum,
                                time: *SystemExclusive.time * newfactor
                            };
                            let sysexgmessage = Message::SYSTEM_EXCLUSIVE((newsysex));
                            eventlist.append(sysexgmessage);
                        },
                    }
                },
                Option::None(_) => { break; }
            };
        };

        // Create a new Midi object with the modified event list
        Midi { events: eventlist.span() }
    }

    fn change_tempo(self: @Midi, new_tempo: u32) -> Midi {
        // Create a clone of the MIDI events
        let mut ev = self.clone().events;

        // Create a new array to store the modified events
        let mut eventlist = ArrayTrait::<Message>::new();

        loop {
            // Use pop_front to get the next event
            match ev.pop_front() {
                Option::Some(currentevent) => {
                    // Process the current event
                    match currentevent {
                        Message::NOTE_ON(_NoteOn) => { eventlist.append(*currentevent); },
                        Message::NOTE_OFF(_NoteOff) => { eventlist.append(*currentevent); },
                        Message::SET_TEMPO(SetTempo) => {
                            // Create a new SetTempo message with the updated tempo
                            let tempo = SetTempo { tempo: new_tempo, time: *SetTempo.time };
                            let tempomessage = Message::SET_TEMPO((tempo));
                            eventlist.append(tempomessage);
                        },
                        Message::TIME_SIGNATURE(_TimeSignature) => {
                            eventlist.append(*currentevent);
                        },
                        Message::CONTROL_CHANGE(_ControlChange) => {
                            eventlist.append(*currentevent);
                        },
                        Message::PITCH_WHEEL(_PitchWheel) => { eventlist.append(*currentevent); },
                        Message::AFTER_TOUCH(_AfterTouch) => { eventlist.append(*currentevent); },
                        Message::POLY_TOUCH(_PolyTouch) => { eventlist.append(*currentevent); },
                        Message::PROGRAM_CHANGE(_ProgramChange) => {
                            eventlist.append(*currentevent);
                        },
                        Message::SYSTEM_EXCLUSIVE(_SystemExclusive) => {
                            eventlist.append(*currentevent);
                        },
                    }
                },
                Option::None(_) => {
                    // If there are no more events, break out of the loop
                    break;
                }
            };
        };

        // Create a new Midi object with the modified event list
        Midi { events: eventlist.span() }
    }

    fn remap_instruments(self: @Midi, chanel: u32) -> Midi {
        // Create a clone of the MIDI events
        let mut ev = self.clone().events;

        // Create a new array to store the modified events
        let mut eventlist = ArrayTrait::<Message>::new();

        loop {
            // Use pop_front to get the next event
            match ev.pop_front() {
                Option::Some(currentevent) => {
                    // Process the current event
                    match currentevent {
                        Message::NOTE_ON(_NoteOn) => { eventlist.append(*currentevent); },
                        Message::NOTE_OFF(_NoteOff) => { eventlist.append(*currentevent); },
                        Message::SET_TEMPO(_SetTempo) => {
                            // Create a new SetTempo message with the updated tempo
                            eventlist.append(*currentevent);
                        },
                        Message::TIME_SIGNATURE(_TimeSignature) => {
                            eventlist.append(*currentevent);
                        },
                        Message::CONTROL_CHANGE(_ControlChange) => {
                            eventlist.append(*currentevent);
                        },
                        Message::PITCH_WHEEL(_PitchWheel) => { eventlist.append(*currentevent); },
                        Message::AFTER_TOUCH(_AfterTouch) => { eventlist.append(*currentevent); },
                        Message::POLY_TOUCH(_PolyTouch) => { eventlist.append(*currentevent); },
                        Message::PROGRAM_CHANGE(ProgramChange) => {
                            let newprogchg = ProgramChange {
                                channel: *ProgramChange.channel,
                                program: next_instrument_in_group(*ProgramChange.program),
                                time: *ProgramChange.time
                            };
                            let pchgmessage = Message::PROGRAM_CHANGE((newprogchg));
                            eventlist.append(pchgmessage);
                        },
                        Message::SYSTEM_EXCLUSIVE(_SystemExclusive) => {
                            eventlist.append(*currentevent);
                        },
                    }
                },
                Option::None(_) => {
                    // If there are no more events, break out of the loop
                    break;
                }
            };
        };

        // Create a new Midi object with the modified event list
        Midi { events: eventlist.span() }
    }

    fn get_bpm(self: @Midi) -> u32 {
        // Iterate through the MIDI events, find and return the SetTempo message
        let mut ev = self.clone().events;
        let mut outtempo: u32 = 0;

        loop {
            match ev.pop_front() {
                Option::Some(currentevent) => {
                    match currentevent {
                        Message::NOTE_ON(_NoteOn) => {},
                        Message::NOTE_OFF(_NoteOff) => {},
                        Message::SET_TEMPO(SetTempo) => { outtempo = *SetTempo.tempo; },
                        Message::TIME_SIGNATURE(_TimeSignature) => {},
                        Message::CONTROL_CHANGE(_ControlChange) => {},
                        Message::PITCH_WHEEL(_PitchWheel) => {},
                        Message::AFTER_TOUCH(_AfterTouch) => {},
                        Message::POLY_TOUCH(_PolyTouch) => {},
                        Message::PROGRAM_CHANGE(_ProgramChange) => {},
                        Message::SYSTEM_EXCLUSIVE(_SystemExclusive) => {},
                    }
                },
                Option::None(_) => { break; }
            };
        };

        outtempo
    }

    fn generate_harmony(self: @Midi, steps: i32, tonic: PitchClass, modes: Modes) -> Midi {
        let mut ev = self.clone().events;
        let mut eventlist = ArrayTrait::<Message>::new();
        let currentmode = mode_steps(modes);

        loop {
            match ev.pop_front() {
                Option::Some(currentevent) => {
                    match currentevent {
                        Message::NOTE_ON(NoteOn) => {
                            let outnote = keynum_to_pc(*NoteOn.note)
                                .modal_transposition(
                                    tonic,
                                    currentmode,
                                    steps.try_into().unwrap(),
                                    if steps < 0 {
                                        Direction::Up(())
                                    } else {
                                        Direction::Down(())
                                    },
                                );

                            let newnote = NoteOn {
                                channel: *NoteOn.channel,
                                note: outnote,
                                velocity: *NoteOn.velocity,
                                time: *NoteOn.time
                            };

                            let notemessage = Message::NOTE_ON((newnote));
                            eventlist.append(notemessage);
                            //include original note
                            eventlist.append(*currentevent);
                        },
                        Message::NOTE_OFF(NoteOff) => {
                            let outnote = if steps < 0 {
                                *NoteOff.note - steps.try_into().unwrap()
                            } else {
                                *NoteOff.note + steps.try_into().unwrap()
                            };

                            let newnote = NoteOff {
                                channel: *NoteOff.channel,
                                note: outnote,
                                velocity: *NoteOff.velocity,
                                time: *NoteOff.time
                            };

                            let notemessage = Message::NOTE_OFF((newnote));
                            eventlist.append(notemessage);
                            //include original note
                            eventlist.append(*currentevent);
                        },
                        Message::SET_TEMPO(_SetTempo) => { eventlist.append(*currentevent); },
                        Message::TIME_SIGNATURE(_TimeSignature) => {
                            eventlist.append(*currentevent);
                        },
                        Message::CONTROL_CHANGE(_ControlChange) => {
                            eventlist.append(*currentevent);
                        },
                        Message::PITCH_WHEEL(_PitchWheel) => { eventlist.append(*currentevent); },
                        Message::AFTER_TOUCH(_AfterTouch) => { eventlist.append(*currentevent); },
                        Message::POLY_TOUCH(_PolyTouch) => { eventlist.append(*currentevent); },
                        Message::PROGRAM_CHANGE(_ProgramChange) => {
                            eventlist.append(*currentevent);
                        },
                        Message::SYSTEM_EXCLUSIVE(_SystemExclusive) => {
                            eventlist.append(*currentevent);
                        },
                    }
                },
                Option::None(_) => { break; }
            };
        };

        Midi { events: eventlist.span() }
    }

    fn arpeggiate_chords(self: @Midi, pattern: ArpPattern) -> Midi {
        panic(array!['not supported yet'])
    }

    fn edit_dynamics(self: @Midi, curve: VelocityCurve) -> Midi {
        let mut ev = self.clone().events;
        let mut vcurve = curve.clone();
        let mut outvelocity = 0;
        let mut eventlist = ArrayTrait::<Message>::new();

        loop {
            match ev.pop_front() {
                Option::Some(currentevent) => {
                    match currentevent {
                        Message::NOTE_ON(NoteOn) => {
                            match vcurve.getlevelattime(*NoteOn.time) {
                                Option::Some(val) => { outvelocity = val; },
                                Option::None => { outvelocity = *NoteOn.velocity; }
                            }

                            let newnote = NoteOn {
                                channel: *NoteOn.channel,
                                note: *NoteOn.note,
                                velocity: outvelocity,
                                time: *NoteOn.time
                            };
                            let notemessage = Message::NOTE_ON((newnote));
                            eventlist.append(notemessage);
                        },
                        Message::NOTE_OFF(NoteOff) => {
                            match vcurve.getlevelattime(*NoteOff.time) {
                                Option::Some(val) => { outvelocity = val; },
                                Option::None => { outvelocity = *NoteOff.velocity; }
                            }
                            let newnote = NoteOff {
                                channel: *NoteOff.channel,
                                note: *NoteOff.note,
                                velocity: outvelocity,
                                time: *NoteOff.time
                            };
                            let notemessage = Message::NOTE_OFF((newnote));
                            eventlist.append(notemessage);
                        },
                        Message::SET_TEMPO(_SetTempo) => { eventlist.append(*currentevent); },
                        Message::TIME_SIGNATURE(_TimeSignature) => {
                            eventlist.append(*currentevent);
                        },
                        Message::CONTROL_CHANGE(_ControlChange) => {
                            eventlist.append(*currentevent);
                        },
                        Message::PITCH_WHEEL(_PitchWheel) => { eventlist.append(*currentevent); },
                        Message::AFTER_TOUCH(_AfterTouch) => { eventlist.append(*currentevent); },
                        Message::POLY_TOUCH(_PolyTouch) => { eventlist.append(*currentevent); },
                        Message::PROGRAM_CHANGE(_ProgramChange) => {
                            eventlist.append(*currentevent);
                        },
                        Message::SYSTEM_EXCLUSIVE(_SystemExclusive) => {
                            eventlist.append(*currentevent);
                        },
                    }
                },
                Option::None(_) => { break; }
            };
        };

        Midi { events: eventlist.span() }
    }

    fn midi_to_bytearray(self: @Midi) -> ByteArray {
        let mut output = ByteArray::new();
        
        // Write header chunk
        output.append(@"MThd".into());
        output.append(@(6_u32).to_be_bytes());
        output.append(@(1_u16).to_be_bytes());
        output.append(@(1_u16).to_be_bytes());
        output.append(@(96_u16).to_be_bytes());

        // Write track chunk
        output.append(@"MTrk".into());
        
        // Placeholder for track length (we'll update this later)
        let track_length_pos = output.len();
        output.append(@(0_u32).to_be_bytes());

        let mut last_time = 0;
        let mut events = *self.events;

        loop {
            match events.pop_front() {
                Option::Some(event) => {
                    match event {
                        Message::NOTE_ON(note_on) => {
                            write_variable_length(&mut output, *note_on.time - last_time);
                            output.append(@(0x90 | *note_on.channel).to_be_bytes());
                            output.append(@(*note_on.note).to_be_bytes());
                            output.append(@(*note_on.velocity).to_be_bytes());
                            last_time = *note_on.time;
                        },
                        Message::NOTE_OFF(note_off) => {
                            write_variable_length(&mut output, *note_off.time - last_time);
                            output.append(@(0x80 | *note_off.channel).to_be_bytes());
                            output.append(@(*note_off.note).to_be_bytes());
                            output.append(@(*note_off.velocity).to_be_bytes());
                            last_time = *note_off.time;
                        },
                        Message::SET_TEMPO(set_tempo) => {
                            write_variable_length(&mut output, *set_tempo.time.unwrap_or(0) - last_time);
                            output.append(@(0xFF_u8).to_be_bytes());
                            output.append(@(0x51_u8).to_be_bytes());
                            output.append(@(3_u8).to_be_bytes());
                            output.append(@(*set_tempo.tempo).to_be_bytes());
                            last_time = *set_tempo.time.unwrap_or(0);
                        },
                        Message::TIME_SIGNATURE(time_sig) => {
                            write_variable_length(&mut output, *time_sig.time.unwrap_or(0) - last_time);
                            output.append(@(0xFF_u8).to_be_bytes());
                            output.append(@(0x58_u8).to_be_bytes()); 
                            output.append(@(4_u8).to_be_bytes()); 
                            output.append(@(*time_sig.numerator).to_be_bytes());
                            output.append(@(*time_sig.denominator).to_be_bytes());
                            output.append(@(*time_sig.clocks_per_click).to_be_bytes());
                            output.append(@(32_u8).to_be_bytes()); 
                            last_time = *time_sig.time.unwrap_or(0);
                        },
                        _ => {}, 
                    }
                },
                Option::None => { break; },
            }
        }

        // Write end of track
        write_variable_length(&mut output, 0);
        output.append(@(0xFF_u8).to_be_bytes());
        output.append(@(0x2F_u8).to_be_bytes());
        output.append(@(0_u8).to_be_bytes());

        // Update track length
        let track_length = output.len() - track_length_pos - 4;
        let track_length_bytes = (track_length as u32).to_be_bytes();
        for i in 0..4 {
            output.set(track_length_pos + i, *track_length_bytes[i]);
        }

        output
    }
}

// Helper function to write variable-length quantities
fn write_variable_length(output: &mut ByteArray, mut value: u32) {
    if value == 0 {
        output.append(@(0_u8).to_be_bytes());
        return;
    }

    let mut buffer = ArrayTrait::new();
    while value > 0 {
        buffer.append(((value & 0x7F) | 0x80) as u8);
        value >>= 7;
    }
    *buffer.at(buffer.len() - 1) &= 0x7F;

    let mut i = buffer.len();
    loop {
        if i == 0 { break; }
        i -= 1;
        output.append(@(*buffer[i]).to_be_bytes());
    }
}
