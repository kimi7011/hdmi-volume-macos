# HDMI Volume driver attribution

The Core Audio HAL driver is adapted from [Jocala Software's eqVol 1.1](https://github.com/Jocala/eqvol/tree/b63ac18e0ec1ca070c23763abbaa24b282becdf5),
which is based on Bitgapp and Roman Kisil's eqMac 1.3.2. See the
[upstream license notice](LICENSE.md).

Changes include removal of the custom property protocol and its unsafe byte
conversion, stable storage for the C factory interface, and an initialized stereo
ring buffer with balanced I/O ownership. Swift Atomics is a pinned build dependency.
