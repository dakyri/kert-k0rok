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
		if (~k0rok != nil, {~k0rok.cull}, {"No loose bits".postln});
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
	//  \inBus,\outBus,\wetAmp,\room,\damp
	SynthDef("freeverb", {
		var sig, wet;
		sig = In.ar(\inBus.kr(9), 2);
		wet = FreeVerb2.ar(sig[0], sig[1],
			mix: \wetAmp.kr(0.3), room: \room.kr(1.0), damp: \damp.kr(0.85));
		Out.ar(\outBus.kr(0), wet);
	}).add;

	// spacey grains!
	//  \inBus,\outBus,\pitch (+/-48),\texture,\fn,\reverb,\size
	SynthDef("clouds", {
		var sig, wet, dens, pos;
		sig = In.ar(\inBus.kr(9), 2);
		dens = LFNoise1.kr(0.3).range(0.3, 0.45);
		pos = LFNoise1.kr(0.3).range(0, 1);
		wet = MiClouds.ar(sig, pit: \pitch.kr(0), pos: pos, size: \size.kr(0), dens: dens,
			tex: \texture.kr(0.5), drywet: \mix.kr(1),
			spread: 1, rvb: \reverb.kr(0.5), fb: \fb.kr(0), mode: 0);
		Out.ar(\outBus.kr(0), wet);
	}).add;

	// main chaos synth. cross and self modulated
	// \freqA, \freqB - main oscilator frequencies
	// \x_depth - cross modulation depth
	// \fb_depth - feedback self modulation depth
	// \amp, \pan, \gate
	// \postFadeSend, \postFadeBus - post fade send and destination
	// \preFadeBus, \preFadeLag, \preFadeSend - pre fade aux. before env, but after filter, gated by (1-env)
	// \cutoff - [-1, 1] sets range and filter type +ve low pass, -ve high pass, 0 none. we are scaled so
	//    that clost to 1 or -1 we are heavily filtered.
	SynthDef("chaosc", {
		arg freqA = 90, freqB = 303, x_depth = 0.1, fb_depth = 0, gate = 0, cutoff = 0, resonance = 0.5;
		var sig, env, pfd_env;
		// LocalIn captures the feedback signal from the previous cycle
		//var fbIn = LeakDC .ar(LocalIn.ar(2), coef: 0.9995);
		var fbIn = LocalIn.ar(2);
		// Cross-modulate the frequencies of two sine oscillators
		var fsigs = SinOsc.ar([freqA, freqB] * ((1 + ((fbIn.reverse * x_depth) + (fbIn * fb_depth))))); // .tanh
		// Send the signals back into the feedback loop
		LocalOut.ar(fsigs);
		sig = \amp.kr(1) * 0.5 * (fsigs[0] + fsigs[1]);
		sig = Select.ar((cutoff.sign + 1), [
			RHPF.ar(sig, cutoff.lincurve(-1, 0, 4000, 20, -4), resonance),
			sig,
			RLPF.ar(sig, cutoff.lincurve(0, 1, 4000, 20, -4), resonance)]);
		sig = Pan2.ar(sig, \pan.kr(0));
		env = EnvGen.kr(Env.asr(\attackT.kr(0), 1, \decayT.kr(0.2), 'linear'), gate);
		pfd_env = \preFadeSend.kr(0).lag(\preFadeLag.kr(1)) * (1 - env);
		Out.ar(\preFadeBus.kr(9), pfd_env * sig);
		sig = env * sig;
		Out.ar(\outBus.kr(0), sig);
		Out.ar(\postFadeBus.kr(11), \postFadeSend.kr(0)*sig);
	}).add;

	SynthDef("rawlf", {
		Out.kr(\lfoBus.kr(0), SinOsc.ar(\beatFreq.kr(1)/\tempo.kr(1)));
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
		baseFreqA: 80,
		freqRatios:  [1,   33/32, 16/15, 12/11, 9/8, 7/6, 11/9, 6/5],
		freqWeights: [0.2, 0.2,   0.1,   0.1,   0.1, 0.1, 0.1,  0.1],
		partch43: [49/48, 33/32, 21/20, 16/15, 12/11, 11/10, 10/9, 9/8, 8/7, 7/6, 32/27, 6/5, 11/9,
				5/4, 14/11, 9/7, 21/16, 4/3, 15/11, 11/8, 7/5, 10/7, 16/11, 22/15, 3/2, 32/21, 14/9, 11/7, 8/5, 18/11,
				5/3, 27/16, 12/7, 7/4, 16/9, 9/5, 20/11, 11/6, 15/8, 40/21, 64/33, 96/49,	2/1],
		players: List.new(),

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
			var freqA = self.baseFreqA * self.freqRatios.wchoose(self.freqWeights);
			var freqB = freqA * self.partch43.choose * [1, 2, 3, 4].wchoose([0.1,0.5,0.3, 0.1]);
			var syn = Synth("chaosc", [
				\freqA: freqA, \freqB: freqB,
				postFadeBus: ~reverbBus, postFadeSend: 0.3, preFadeBus: ~grainBus,
				x_depth: 0.1, fb_depth: 0, resonance: 0.2, pan: 0]);
			var handle = (
				type: \composite,
				synth_n: syn,
				tos: { | self, nm | (nm ++ '_' ++ syn.nodeID).asSymbol; },
				ssy: { | self, x, y | self.synth_n.set(x, y); },
				msy: { | self, x, y | self.synth_n.map(x, y.asBus); },
				pattern: Pbind(type: \set),
				pruner: nil,
				state: 'planted',

				/*! dowa most of the normal running setup here */
				init: { | self |
					var pan_w = 0.3;
					var panc = rrand(pan_w - 1, 1 - pan_w);
					var pan_lfrate = rrand(1, 1.5);
					var x_base = rrand(0.4, 0.7);
					var fb_base = rrand(0.05, 0.15);
					var cutoff_base = rrand(0.6, 0.8);
					var pat;

					postf("synth %, freqA %, freqB %, cutoff %, fb % x %",
						syn.nodeID, freqA, freqB, cutoff_base, fb_base, x_base);

					Ndef(self.tos('lf1'), { SinOsc.kr(TempoClock.tempo / [63, 137].choose, pi*[0, 0.5, 1, 1.5].choose) });
					Ndef(self.tos('lf2'), { SinOsc.kr(TempoClock.tempo / [37, 97].choose, pi*[0, 0.5, 1, 1.5].choose) });
					Ndef(self.tos('lf3'), { SinOsc.kr(TempoClock.tempo / [1, 4].choose, pi*[0, 0.5, 1, 1.5].choose) });
					Ndef(self.tos('lf4'), { SinOsc.kr(TempoClock.tempo / [1, 4].choose, pi*[0, 0.5, 1, 1.5].choose) });
					Ndef(self.tos('env1'), { EnvGen.kr(
						Env([0, 0, 1, 1, 0],
							[[11, 21].choose, [3, 30].choose, [2, 12].choose, [3, 30].choose],
							releaseNode: 3, loopNode: 0)) });
					Ndef(self.tos('env2'), { EnvGen.kr(
						Env([0, 0, 1, 1, 0],
							[[11, 21].choose, [3, 30].choose, [2, 12].choose, [3, 30].choose],
							releaseNode: 3, loopNode: 0)) });

					pat =  Pbind(type: \set, id: syn, args: [\gate, \pan, \cutoff, \x_depth],
						gate: Pseq([1, 0], inf),
						x_depth: Ndef(self.tos('x_lf'),
							{ ((0.9 * Ndef(self.tos('lf2')).kr) + (0.1 * Ndef(self.tos('lf4')).kr))
								.linlin(-1, 1, x_base - 0.3, x_base + 0.3)}),
						fb_depth: Ndef(self.tos('fb_lf'),
							{ ((0.8 * Ndef(self.tos('lf1')).kr) + (0.1 * Ndef(self.tos('lf4')).kr))
								.linlin(-1, 1, fb_base - 0.05, fb_base + 0.05)}),
						cutoff: Ndef(self.tos('cutoff_lf'),
							{ ((0.9 * Ndef(self.tos('lf1')).kr) + (0.1 * Ndef(self.tos('lf3')).kr))
								.linlin(-1, 1, cutoff_base - 0.15, cutoff_base + 0.15)}),
						pan: Ndef(self.tos('pan_lf'),
							{ SinOsc.kr(pan_lfrate).linlin(-1, 1, panc - pan_w, panc + pan_w)}),
						dur: Pseq([2, 3], inf)
					).play;
					self.pattern = pat;
					self.state = 'flowering';
					self;
				},

				/*! kick this particular thread into it's final stage and clean it up */
				prune: { | self, prune_t = 0 |
					self.pruner = Routine({
						/* maybe find a way to wait until our env is 0 */
						self.pattern.stop;
						self.pattern.free;
						prune_t.yield;
						/*loop {
							delta = rrand(1, 3) * 0.5;
							"Will wait ".post;
							delta.postln;
							delta.yield;
						}*/
						Ndef(self.tos('pan_lf')).clear;
						Ndef(self.tos('x_lf')).clear;
						Ndef(self.tos('fb_lf')).clear;
						Ndef(self.tos('cutoff_lf')).clear;

						Ndef(self.tos('lf1')).clear;
						Ndef(self.tos('lf2')).clear;
						Ndef(self.tos('lf3')).clear;
						Ndef(self.tos('lf4')).clear;
						Ndef(self.tos('env1')).clear;
						Ndef(self.tos('env2')).clear;
						self.synth_n.free;
						self.state = 'compost';
					}).play;
				}
			);
			self.players.add(handle);
			handle.init(); // returns the handle so 'spawn' can return it
		},
		/*! stop and cleanup a particular synth, and associated patterns and lfos */
		cull: { |self|
			self.players.do({|player, i| player.prune;});
			self.players.reverseDo({|item, i| self.players.pop.postln;});
		},
		/*! run a loop that will randomly launch and delete chaosc synths */
		play: { |self| }
	)
})
)

~k0rok.freq
~k0rok.baseFreqA
~k0rok.freqRatios.wchoose(~k0rok.freqWeights)
p = ~k0rok.spawn
p.prune
~k0rok.cull
p.ssy(\cutoff, 1)
p.ssy(\cutoff, -1)
p.ssy(\resonance, 1)
p.ssy(\x_depth, 1.2)
p.ssy(\fb_depth, 0.1)
p.ssy(\freqA, 27)
p.ssy(\freqB, 97)
p.aay(\gate, 0)
p.ssy(\preFadeSend, 1)
p.msy(\x_depth, Ndef(\lf, {SinOsc.ar(0.25)* 0.5 + 1.2}))

f = ({|x| x.lincurve(-1, 0, 20000, 20, -6)})

f.(-1)
~clouds.set(\pitch, -3.7)
~x = 1
(~x == 1).asInt
Ndef(\lf, { SinOsc.ar(5)} )
(
~s1 = Synth("chaosc", [\preFadeBus, ~grainBus, \postFadeBus, ~reverbBus , \freqA, 16, \freqB, 37, \depth, 1,
	\pan -0.1])
)
~s1.set(\preFadeSend, 1)
~s1.set(\gate, 0)
~s1.set(\x_depth, 1.4)
~s1.set(\modBtoA, 100)
~s1.set(\freqA, 17)
~s1.set(\freqB, 15)
~s1.map(\x_depth, Ndef(\lfx, { SinOsc.kr(0.3).linlin(-1, 1, 0.3, 2) }).asBus)
Ndef(\lfx, { SinOsc.kr(0.05).linexp(-1, 1, 1.3, 4) }).asBus
~s1.nodeID
~s1.free
Ndef(\lfx, { ~lfo1Bus.kr(1).exprange(100, 2000) })
Ndef(\lfx, { SinOsc.kr(0.1) });
~s1.set(\cutoff, 590)
~s1.map(\cutoff, Ndef(\lfo2, { SinOsc.kr(0.25).exprange(200, 600)}).asBus)
~s1.map(\depth, Ndef(\lfo3, { SinOsc.kr(3) + SinOsc.kr(0.09123) }).asBus)
~s1.map(\pan, Ndef(\lfo4, { SinOsc.kr(0.1) }).asBus)
~s1.set(\pan, 1)
~clouds.set(\pitch, -13)
~clouds.set(\fb, 0.25)
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

-1.linexp(-1, 0, 20000, 50)
{ 