(
s.waitForBoot(
	Buffer.freeAll;
//	s.sync;

/*
 * create global buses and groups
 */
//	s.sync;
	s.newBusAllocators;
	~reverbBus = Bus.audio(s, 2); // collective output for supports and pads
	~grainBus = Bus.audio(s, 2); // collective output for processed sound
	~mainOut = 0; // audio out, 2 channel

	~synthGrp = Group.new; // group for direct and strand players
	~masterFXGrp = Group.after(~playGrp); // group for any master fx
	~masterOutGrp = Group.after(~masterFXGrp); // group for main hardware io

	~cleanup = {
		ServerBoot.removeAll;
		ServerQuit.removeAll;
		ServerTree.removeAll;
		CmdPeriod.removeAll;
	};
	ServerQuit.add(~cleanup);
//	~cleanup();

	~root = PathName(thisProcess.nowExecutingPath).pathOnly;
	~csvdata = CSVFileReader.read(~root +/+ "floranium-data.csv", true, true);
	~v1 = ~csvdata.collect({ |item, i| item[1].asFloat });
	~v2 = ~csvdata.collect({ |item, i| item[2].asInteger });

	// reverb synth, stereo->stereo
	//  \inBus - source
	//  \outBus - destination
	//  \wetAmp
	//  \room
	//  \damp
	SynthDef("freeverb", { arg inBus = 9, outBus = 0;
		var sig, wet;
		sig = In.ar(inBus, 2);
		wet = FreeVerb2.ar(sig[0], sig[1],
			mix: \wetAmp.kr(0.3), room: \room.kr(1.0), damp: \damp.kr(0.85));
		Out.ar(outBus, wet);
	}).add;
)


)

(
SynthDef("chaosc", { arg outBus = 0, freqA = 32, freqB = 48, modAtoB = 227, modBtoA = 80, pan = 0, amp = 1;
    // LocalIn captures the feedback signal from the previous cycle
	var sig;
    var fbIn = LocalIn.ar(2);
    // Cross-modulate the frequencies of two sine oscillators
    var fsigs = SinOsc.ar([freqA, freqB] + (fbIn.reverse * [modBtoA, modAtoB]));
    // Send the signals back into the feedback loop
    LocalOut.ar(fsigs);
	sig = 0.5 * (fsigs[0] + fsigs[1]);
	Out.ar(outBus, Pan2.ar(amp * sig, pan));
}).add;
)

Synth("chaosc", [\freq, 100, \ratio, 1.7]);

(
~notes = Array.fill(128, nil);

MIDIdef.noteOn(\on, {
	arg val, num;
	~notes.put(
		num,
		Synth("chaosc", [
			\freq, num.midicps,
			\harm, 20,
			\amp, val.linlin(0,127,-30, -6).dbamp,
			\gate, 1
		]);
	);
});

MIDIdef.noteOff(\off, {
	arg val, num;
	~notes[num].set(\gate, 0);
	~notes[num] = nil;
});
)


(
SynthDef(\fm, {
	var sig, mod, env, ienv;
	ienv = Env([1,\ipeak.ir(7),1], [\iatk.ir(0.01),\irel.ir(0.2)], [1,-3]).ar;
	env = Env([0,1,0], [\atk.ir(0.01),\rel.ir(3)], [1,-1]).ar(0.2);
	mod = SinOsc.ar(
		\freq.kr(400) * \ratio.kr(2),
		mul:\freq.kr(400) * \ratio.kr(2) * ienv
	);
	sig = SinOsc.ar(\freq.kr(400) + mod);
	sig = Pan2.ar(sig, \pan.kr(0), \amp.kr(0.1));
	sig = sig * env;
	Out.ar(\out.ir(0), sig);
}).add;
)

(
Ndef(\xfm, {
    arg freqA = 32, freqB = 9, modAtoB = 227, modBtoA = 110;
    // LocalIn captures the feedback signal from the previous cycle
    var fbIn = LocalIn.ar(2);
    // Cross-modulate the frequencies of two sine oscillators
    var sigs = SinOsc.ar([0.8 * freqA, 0.9 * freqB] + (fbIn.reverse * [modBtoA, modAtoB]));
    // Send the signals back into the feedback loop
    LocalOut.ar(sigs);
    sigs * 0.5;
}).play;
)

(
SynthDef(\fm, {
	var sig, mod, mod2, env;
	env = Env([0,1,0],[\atk.ir(0.01),\rel.ir(10)],[1,-1]).ar(2);
	mod2 = SinOsc.ar(
		\freq.kr(400) * \ratio2.kr(0.5/400),
		mul: \freq.kr(400) * \ratio2.kr(0.5/400) * \index2.kr(16)
	);
	mod = SinOsc.ar(
		(\freq.kr(400) * \ratio.kr(8/400)) + mod2,
		mul: \freq.kr(400) * \ratio.kr(8/400) * \index.kr(16);
	);
	sig = SinOsc.ar(\freq.kr(400) + mod);
	sig = Pan2.ar(sig, \pan.kr(0), \amp.kr(0.2));
	sig = sig * env;
	Out.ar(\out.ir(0), sig);
}).add;
)
Synth(\fm, [\freq, 100, \ratio, 1.7]);

(
// the arg direct will control the proportion of direct to processed signal
SynthDef("tutorial-DecayPink", { arg outBus = 0, effectBus, direct = 0.5;
    var source;
    // Decaying pulses of PinkNoise. We'll add reverb later.
    source = Decay2.ar(Impulse.ar(1, 0.25), 0.01, 0.2, PinkNoise.ar);
    // this will be our main output
    Out.ar(outBus, source * direct);
    // this will be our effects output
    Out.ar(effectBus, source * (1 - direct));
}).add;

SynthDef("tutorial-DecaySin", { arg outBus = 0, effectBus, direct = 0.5;
    var source;
    // Decaying pulses of a modulating sine wave. We'll add reverb later.
    source = Decay2.ar(Impulse.ar(0.3, 0.25), 0.3, 1, SinOsc.ar(SinOsc.kr(0.2, 0, 110, 440)));
    // this will be our main output
    Out.ar(outBus, source * direct);
    // this will be our effects output
    Out.ar(effectBus, source * (1 - direct));
}).add;

SynthDef("tutorial-Reverb", { arg outBus = 0, inBus;
    var input;
    input = In.ar(inBus, 1);

    // a low-rent reverb
    // aNumber.do will evaluate its function argument a corresponding number of times
    // {}.dup(n) will evaluate the function n times, and return an Array of the results
    // The default for n is 2, so this makes a stereo reverb
    16.do({ input = AllpassC.ar(input, 0.04, { Rand(0.001,0.04) }.dup, 3)});

    Out.ar(outBus, input);
}).add;

b = Bus.audio(s,1); // this will be our effects bus
)

(
x = Synth.new("tutorial-Reverb", [\inBus, b]);
y = Synth.before(x, "tutorial-DecayPink", [\effectBus, b]);
z = Synth.before(x, "tutorial-DecaySin", [\effectBus, b, \outBus, 1]);
)

// Change the balance of wet to dry
y.set(\direct, 1); // only direct PinkNoise
z.set(\direct, 1); // only direct Sine wave
y.set(\direct, 0); // only reverberated PinkNoise
z.set(\direct, 0); // only reverberated Sine wave
x.free; y.free; z.free; b.free;


b = Buffer.read(s, Platform.resourceDir +/+ "sounds/a11wlk01-44_1.aiff");

(  // basic granulation
{
    var input = PlayBuf.ar(1, b, 1, loop: 1)!2;

    var dens = LFNoise1.kr(0.3).range(0.3, 0.45);
    MiClouds.ar(input, 0, 0, 0, dens, 0.5, drywet: 1, mode: 0);

}.play
)

