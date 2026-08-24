# Speech-model notices

## NVIDIA Parakeet TDT 0.6B v3

The built-in transcription engine downloads a Core ML conversion of NVIDIA's
Parakeet TDT 0.6B v3 on first use. Model weights are not embedded in this
repository or the application bundle.

- Original model: [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- Core ML conversion used by FluidAudio: [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml)
- Model license: [Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/)

Parakeet v3 supports 25 European languages, including Russian and English.
It is multilingual, not universal; quality can vary with language mixing,
accent, audio quality, names, and specialist vocabulary.

The conversion changes the model representation for Apple Core ML inference.
NVIDIA and FluidInference do not endorse this application.

If a distributor later embeds model weights into an app or archive, it must
also ship the applicable CC BY attribution, source, license, and modification
notice with that distribution.
