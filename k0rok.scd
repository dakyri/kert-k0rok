(
s.waitForBoot({
	Buffer.freeAll;
	s.freeAll;
	s.sync;

/*
 * create global buses and groups
 */
	~cleanup = {
		ServerBoot.removeAll;
		ServerQuit.removeAll;
		ServerTree.removeAll;
		CmdPeriod.removeAll;
		"cleaned up...".postln;
	};
	ServerQuit.add(~cleanup);
	~cleanup.value;

	s.newBusAllocators;
	~reverbBus = Bus.audio(s, 2); // collective output for supports and pads
	~grainBus = Bus.audio(s, 2); // collective output for processed sound
	~mainOut = 0; // audio out, 2 channel

	~dataInBus = Bus.control(s, 1);
	~lfo1Bus = Bus.control(s, 1);
	~lfo2Bus = Bus.control(s, 1);

	~synthGrp = Group.new; // group for direct and strand players
	~fXGrp = Group.after(~synthGrp); // group for any master fx

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
	SynthDef("freeverb", {
		arg inBus = 9, outBus = 0;
		var sig, wet;
		sig = In.ar(inBus, 2);
		wet = FreeVerb2.ar(sig[0], sig[1],
			mix: \wetAmp.kr(0.3), room: \room.kr(1.0), damp: \damp.kr(0.85));
		Out.ar(outBus, wet);
	}).add;

	SynthDef("clouds", {
		arg inBus = 9, outBus = 0, pitch = 0, size = 0, texture = 0.5, mix = 1, reverb = 0.5, fb = 0;
		var sig, wet, dens, pos;
		sig = In.ar(inBus, 2);
		dens = LFNoise1.kr(0.3).range(0.3, 0.45);
		pos = LFNoise1.kr(0.3).range(0, 1);
		wet = MiClouds.ar(sig, pit: pitch, pos: pos, size: size, dens: dens, tex: texture, drywet: mix,
			spread: 1, rvb: reverb, fb: fb, mode: 0);
		Out.ar(outBus, wet);
	}).add;

	s.sync;

	~rvb = Synth("freeverb", [\inBus, ~reverbBus], ~fXGrp);
	~clouds = Synth("clouds", [\inBus, ~grainBus, \reverb, 0.3], ~fXGrp);
})
)


// main synth
(
SynthDef("chaosc", {
	arg freqA = 16, freqB = 9, modAtoB = 133, modBtoA = 137, depth = 1, gate = 0;
    // LocalIn captures the feedback signal from the previous cycle
	var sig, env;
    var fbIn = LocalIn.ar(2);
    // Cross-modulate the frequencies of two sine oscillators
    var fsigs = SinOsc.ar([freqA, freqB] + (fbIn.reverse * [modBtoA*depth, modAtoB*depth]));
    // Send the signals back into the feedback loop
    LocalOut.ar(fsigs);
	sig = \amp.kr(1) * 0.5 * (fsigs[0] + fsigs[1]);
	sig = RLPF.ar(sig, \cutoff.kr(20000), \resonance.kr(1.0));
	sig = Pan2.ar(sig, \pan.kr(0));
	Out.ar(\preFadeBus.kr(9), \preFadeSend.kr(0)*sig);
	env = EnvGen.kr(Env.asr(\attackT.kr(0), 1, \decayT.kr(0.2), 'linear'), gate);
	sig = env * sig;
	Out.ar(\outBus.kr(0), sig);
	Out.ar(\postFadeBus.kr(11), \postFadeSend.kr(0)*sig);
}).add;
)

~synthGrp.dumpTree
~fXGrp.dumpTree
~reverbBus
~s1 = Synth("chaosc", [\preFadeBus, ~grainBus, \postFadeBus, ~reverbBus , \freqA, 16, \freqB, 37, \depth, 1], ~synthGrp);
~s1.set(\gate, 1)
~s1.set(\gate, 0)
~s1.set(\depth, 1.2)
~s1.set(\pan, -0.5)
~s1.set(\cutoff, 400);
~s1.set(\resonance, 0.8);
~s1.set(\postFadeSend, 0.1);
~s1.set(\preFadeSend, 0);
~s1.set(\modAtoB, 100)
~s1.set(\modBtoA, 200)
~s1.free

{Out.kr(0, SinOsc.kr(0.5))}.play
{Out.kr(1, 150 + 40 * SinOsc.kr(0.5))}.play

~s1.nodeID
(
p = Pbind(
    \type, \set,
    \id, ~s2.nodeID,
    \args, [\gate],
	\gate, Pseq([1, 0], inf),
	\dur, 1
).play;
)
p.stop
~s2 = Synth("chaosc", [\freqA, 17, \freqB, 45, \modAtoB, 90, \modBtoA, 241, \depth, 1], ~synthGrp);
~s2.set(\gate, 1)
~s2.set(\gate, 0)
~s2.set(\depth, 0.9)
~s2.set(\pan, 0.6)
~s2.set(\freqB, 11)
~s2.set(\modAtoB, 116)
~s2.set(\modBtoA, 406)
~s2.free

// Run the routine
(
~dataBusSender = Routine({
    // Convert the Env into a stream
	var dataEnv = Env(~v1, [10], \lin);
	var envStream = dataEnv.asStream;
	var val, val2;

    // Loop while values are still being generated
    loop {
		val = envStream.next;
		val2 = 5 * (val - 1.5); // Print current envelope value to post window
		~s2.set(\depth, val2);
		s.bind { ~dataInBus.set(val2) };
		if (thisThread.beats > e.endBeat) { envStream = dataEnv.asStream; }
        0.1.wait;
    };
}).play;
)

~r3.stop
~r3.free;
s.freeAll
(
f = Routine({
	var env = Env([0, 1, 0], [5, 5]);
	e = env.asStream;
	loop {
		e.value.post;
		' '.post;
		e.endBeat.post;
		' '.post;
		thisThread.beats.postln;
		0.1.wait;
		if (thisThread.beats > e.endBeat) { e = env.asStream; }
	}
}).play;

)
f.reset

/*
in supercollider what's the best way to get a smooth control signal from an array of values

It depends on how you want to move through the array. These are the main options, roughly in order of how often you'll want them.
1. Time-based, one-shot: Env + EnvGen

Use this when the values should unfold over time with shaped transitions.
supercollider

(
{
    var vals = [200, 800, 400, 1200, 300];
    var env = Env(vals, [0.5, 1, 0.25, 2], \sin);   // or \lin, \exp, a number for curvature
    var freq = EnvGen.kr(env, doneAction: 2);
    SinOsc.ar(freq) * 0.1
}.play
)

\sin gives smooth S-curves between points. \exp sounds more natural for frequencies (all values must be > 0), and a number like -4 gives custom curvature. Env.xyc lets you set a curve per segment.
2. Looping or endless: DemandEnvGen

This works like an envelope, but it reads its levels and durations from demand UGens, so it can cycle forever:
supercollider

(
{
    var freq = DemandEnvGen.kr(
        Dseq([200, 800, 400, 1200, 300], inf),
        Dseq([0.5, 1, 0.25], inf),
        shape: Env.shapeNumber(\sin)
    );
    SinOsc.ar(freq) * 0.1
}.play
)

You can swap Dseq for Drand, Dxrand, or Dwhite to get random smooth walks.
3. Position-based lookup: IEnvGen or SelectX

Use this when another signal (an LFO, a mouse position, a phasor) should scan through the array:
supercollider

(
{
    var vals = [200, 800, 400, 1200, 300];
    var pos = LFTri.kr(0.2).range(0, vals.size - 1);
    var freq = IEnvGen.kr(Env(vals, 1 ! (vals.size - 1), \sin), pos);
    // or linear crossfade: SelectX.kr(pos, vals)
    SinOsc.ar(freq) * 0.1
}.play
)

For long arrays, you can load them into a Buffer and use BufRd.kr(1, buf, phase, interpolation: 4) for cubic interpolation.
4. Stepped values plus smoothing

This is quick and flexible. Step through the values with Duty, then smooth the steps with Lag, VarLag, or Lag3:
supercollider

freq = Lag3.kr(Duty.kr(0.25, 0, Dseq(vals, inf)), 0.2);

This gives an "approach" feel rather than exact arrival times. VarLag also takes a curve argument.
Changing the array at runtime

Use an array control with a fixed size, then .set it from the language:
supercollider

SynthDef(\sm, { |dur = 1|
    var vals = \vals.kr([200, 800, 400, 1200]);
    var freq = DemandEnvGen.kr(Dseq(vals, inf), dur, Env.shapeNumber(\sin));
    Out.ar(0, SinOsc.ar(freq) * 0.1 ! 2);
}).add;

x = Synth(\sm);
x.set(\vals, [300, 600, 900, 450]);

For patterns on the language side, Pseg does the same job as Env, interpolating values over time inside a Pbind.

Rule of thumb: use Env/EnvGen for a fixed gesture, DemandEnvGen for something that loops or evolves, and IEnvGen/SelectX when you want to scrub through the array with another signal.


Create a control bus, call .set on it from inside the routine, and read it on the server with In.kr or by mapping a synth argument to it.
supercollider
*/
s.boot;

// 1. Allocate a control bus
~bus = Bus.control(s, 1);

// 2. A synth that reads from the bus
(
SynthDef(\sine, { |out = 0, freq = 440, amp = 0.1|
    Out.ar(out, SinOsc.ar(freq.lag(0.05)) * amp ! 2);
}).add;
)

~synth = Synth(\sine);
~synth.map(\freq, ~bus);   // freq now follows the bus

// 3. A routine that writes a stream of values to the bus
(
~r = Routine {
    var stream = Pwhite(200, 800).asStream;   // any stream/data source
    loop {
        s.bind { ~bus.set(stream.next) };      // timestamped write
        0.1.wait;
    }
}.play;
)

// stop / clean up
~r.stop; ~synth.free; ~bus.free;
/*
Some notes:

    Why s.bind? On its own, ~bus.set(val) sends the /c_set message right away, so the timing jitters with the language clock. Wrapping it in s.bind { } gives the message the server's latency timestamp. That keeps the timing tight, and in sync with any patterns you have running.
    Other ways to read the bus:
        Inside a SynthDef: In.kr(~bus), or pass the bus in as an argument: In.kr(\busIn.kr).
        When creating a synth: Synth(\sine, [\freq, ~bus.asMap]).
    Multichannel data: use Bus.control(s, n) and write with ~bus.setn([v1, v2, v3]).
    Smoothing: bus values jump from step to step. Add .lag or Lag.kr on the reading side, as in the example, to avoid zipper noise.
    Checking values from the language: ~bus.get { |v| v.postln } works on any server. ~bus.getSynchronous only works on the local server with shared memory.
*/




{
	SinOsc.kr(

{LPF.ar(Saw.ar(200, 0.1), SinOsc.kr(XLine.kr(0.7, 300, 20), 0, 3600, 4000)) }.play;

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

b = Buffer.read(s, Platform.resourceDir +/+ "sounds/a11wlk01-44_1.aiff");

(  // basic granulation
{
    var input = PlayBuf.ar(1, b, 1, loop: 1)!2;

    var dens = LFNoise1.kr(0.3).range(0.3, 0.45);
    MiClouds.ar(input, 0, 0, 0, dens, 0.5, drywet: 1, mode: 0);

}.play
)

(
Ndef(\xfm, { arg freqA = 16, freqB = 9, modAtoB=133, modBtoA=137;
	var fbIn = LocalIn.ar(2);
	var sigs = SinOsc.ar([freqA, freqB] + (fbIn.reverse * [modBtoA, modAtoB]));
	LocalOut.ar(sigs);
	sigs * 0.5;
}).play;
)

// Make sure the server is booted
s.boot;

