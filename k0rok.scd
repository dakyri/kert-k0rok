(
s.waitForBoot(
	Buffer.freeAll;
//	s.sync;

/*
 * create global buses and groups
 */
//	s.sync;
	s.newBusAllocators;
	~padOutBus = Bus.audio(s, 2); // collective output for supports and pads
	~voiceOutBus = Bus.audio(s, 2); // collective output for processed sound
	~mainOut = 0; // audio out, 2 channel

	~playGrp = Group.new; // group for direct and strand players
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

	// reverb synth, stereo->stereo
	//  \inBus - source
	//  \outBus - destination
	//  \mix
	//  \room
	//  \damp
	SynthDef(\rev, {
		var sig, wet;
		sig = In.ar(\inBus.ir(0), 2);
		wet = FreeVerb2.ar(sig[0], sig[1],
			mix: \wetAmp.kr(0.3), room: \room.kr(1.0), damp: \damp.kr(0.85));
		Out.ar(\outBus.ir(0), wet);
	}).add;
)


)
~root = "C:/sounds/supercollider/kert-k0rok";


x = CSVFileReader.read(~root +/+ "floranium-data.csv", true, true).postcs
x[0][1]

~root +/+ "floranium-data.csv"