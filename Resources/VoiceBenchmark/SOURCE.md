# Voice benchmark sample

30 seconds of 16-bit PCM speech made by repeating and trimming whisper.cpp v1.9.1 samples/jfk.wav. John F. Kennedy's presidential inaugural address, January 20, 1961, a US federal government speech (public domain). The repetition is for a reproducible timing workload, not a transcription-quality evaluation. Upstream source commit f049fff95a089aa9969deb009cdd4892b3e74916. Source: https://github.com/ggml-org/whisper.cpp/blob/v1.9.1/samples/jfk.wav

## Reference transcript (0.5.317)

`speech-30s.txt` is what the sample says, for the onboarding engine check's word error rate (lowercase, punctuation
stripped, 58 words). It is a public-domain excerpt of the 1961 inaugural address. The sample is byte-identical to two
copies of whisper.cpp's `samples/jfk.wav` (11.000 s each) followed by its first 8.000 s. That 8.000 s cut falls in a
pause (RMS about 300 from 7.55 s to 8.15 s; speech resumes at 8.15 s), so the third copy ends cleanly after "for you".
Machine-checked on 2026-10-16: whisper.cpp large-v3-turbo transcribed the sample to exactly this text. A human listen
is still pending. One 30 s clip is a sanity check, not an accuracy benchmark, and COS Control never presents it as one.
