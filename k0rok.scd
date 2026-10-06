(
s.waitForBoot({
	Buffer.freeAll;
	s.freeAll;
	s.sync;

	// create global buses and groups
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

	// spacey grains!
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

	// main synth
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

	SynthDef("rawlf", {
		Out.kr(\lfoBus, SinOsc.ar(\beatFreq.kr(1)/\tempo.kr(1)));
	}).add;

	s.sync;

	~rvb = Synth("freeverb", [\inBus, ~reverbBus], ~fXGrp);
	~clouds = Synth("clouds", [\inBus, ~grainBus, \reverb, 0.3], ~fXGrp);

	// send our data stream from the plants to a bus as an lf signal.
	// currently just an env of fixed data. ideally an actual data stream.
	~dataBusSender = Routine({
		// Convert the Env into a stream
		var dataEnv = Env(~v1, [10], \lin);
		var envStream = dataEnv.asStream;
		var val, val2;

		// Loop while values are still being generated
		loop {
			val = envStream.next;
			val2 = 5 * (val - 1.5); // Print current envelope value to post window
			s.bind { ~dataInBus.set(val2) }; // s.bind will timestamp the stream, reducing jitter
			if (thisThread.beats > envStream.endBeat) { envStream = dataEnv.asStream; };
			0.1.wait;
		};
	});

	~voltageLF = ~dataBusSender.play;
	~lf1 = Synth("rawlf", [\lfoBus, ~lfo1Bus, \beatFreq, 63]);
	~lf2 = Synth("rawlf", [\lfoBus, ~lfo2Bus, \beatFreq, 99]);

	~k0rok = (
		type: \composite,
		baseFreqA: 16,
		baseFreqB: 9,
		freqRatios: [1, 16/15, 9/8, 6/5, 5/4, 4/3, 3/2, 7/4, 2,   5/2],
		freqRatios: [0.1, 0.1, 0.2, 0.1, 0.2, 0.1, 0.0.05, 0.05, 0.05, 0.05],
		baseModAtoB: 133,
		baseModBtoA: 137,
		init: { |self| },
		/*!
         * launch a synth, associated patterns and lfos
		 *  - a synth
		 *  - pattern for main gate
		 *  - pattern for prefade sends to MIClouds
		 *  - random f1 and f2. maybe rations from a constant root
		 *  - Ndef lfos.
         *      - slow multiple parallel lfo for cutoff, freq, modAtoB, modeBtoA
		 *      - voltage LF to cross modulation amount
         *      - pan (random centre, fast wobbke +- 0.05
         */
		spawn: { |self|
			var syn = Synth("chaosc", [
				\freqA, self.baseFreqA * self.freqRatios.wchoose(self.freqWeights),
				\freqB, self.baseFreqB * self.freqRatios.wchoose(self.freqWeights),
				\postFadeBus, ~reverbBus, \postFadeSend, 0.3, \preFadeBus, ~grainBus,
				\depth, 1, \pan -0.1]);
			var pat1 = Pbind(type: \set, id: syn, args: [\gate], gate: Pseq([1, 0], inf),
				dur: 1).play;
			var pat2 = nil;
		},
		/*! stop and cleanup a particular synth, and associated patterns and lfos */
		cull: { |self| },
		/*! run a loop that will randomly launch and delete chaosc synths */
		play: { |self| }
	)
})
)
16/15
TempoClock.default.tempo.postln;
(
~s1 = Synth("chaosc", [\preFadeBus, ~grainBus, \postFadeBus, ~reverbBus , \freqA, 16, \freqB, 37, \depth, 1,
	\pan -0.1])
)
~lf1 = Synth("rawlf")
~s1.nodeID
~s1.
Ndef(\lfo2, { ~lfo1Bus.kr(1).exprange(100, 2000) })
Ndef(\lfo3, { SinOsc.kr(0.1) });
~s1.set(\depth, -1)
~s1.set(\cutoff, 590)
~s1.map(\cutoff, Ndef(\lfo2, { SinOsc.kr(0.25).exprange(200, 600)}).asBus)
~s1.map(\depth, Ndef(\lfo3, { SinOsc.kr(3) + SinOsc.kr(0.09123) }).asBus)
	~s1.map(\pan, Ndef(\lfo4, { SinOsc.kr(0.1) }).asBus)
	~s1.set(\pan, 1)
)
~s1.set(\, 1)
(
p = Pbind(
	\type, \set,
	\id, ~s1.nodeID,
	\preFadeSend, 1
).play;
)
p.stop
~s1.free
p.free
Ndef(\lfo4, { SinOsc.kr(0.1) })
~synthGrp.dumpTree
~fXGrp.dumpTree
~reverbBus
~synthGrp)2
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
			s.bind { ~dataInBus.set(val2) }; // s.bind will timestamp the stream, reducing jitter
			if (thisThread.beats > e.endBeat) { envStream = dataEnv.asStream; };
		0.1.wait;
		};
	});
)

// NOTE TO SELF. set needs the \args to be specific for gates parameters to work
(
p = Pbind(
    \type, \set,
    \id, ~s2,
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

