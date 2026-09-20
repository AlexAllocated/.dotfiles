import argparse
import ctypes as c
import math
import random
import time


class Hint(c.Structure):
    _fields_ = [("descriptor", c.c_int), ("lower", c.c_float), ("upper", c.c_float)]


class Descriptor(c.Structure):
    pass


Instantiate = c.CFUNCTYPE(c.c_void_p, c.POINTER(Descriptor), c.c_ulong)
Connect = c.CFUNCTYPE(None, c.c_void_p, c.c_ulong, c.POINTER(c.c_float))
Activate = c.CFUNCTYPE(None, c.c_void_p)
Run = c.CFUNCTYPE(None, c.c_void_p, c.c_ulong)
Cleanup = c.CFUNCTYPE(None, c.c_void_p)
Descriptor._fields_ = [
    ("id", c.c_ulong), ("label", c.c_char_p), ("properties", c.c_int),
    ("name", c.c_char_p), ("maker", c.c_char_p), ("copyright", c.c_char_p),
    ("port_count", c.c_ulong), ("port_descriptors", c.POINTER(c.c_int)),
    ("port_names", c.POINTER(c.c_char_p)), ("hints", c.POINTER(Hint)),
    ("implementation", c.c_void_p), ("instantiate", Instantiate),
    ("connect", Connect), ("activate", Activate), ("run", Run),
    ("run_adding", c.c_void_p), ("set_run_adding_gain", c.c_void_p),
    ("deactivate", c.c_void_p), ("cleanup", Cleanup),
]


def probe(plugin):
    library = c.CDLL(plugin)
    library.ladspa_descriptor.restype = c.POINTER(Descriptor)
    pointer = library.ladspa_descriptor(0)
    descriptor = pointer.contents
    print("Plugin:", descriptor.label.decode(), flush=True)
    started = time.monotonic()
    instance = descriptor.instantiate(pointer, 48000)
    if not instance:
        raise RuntimeError("NVIDIA AFX could not initialize the model on this GPU")
    print(f"Model loaded in {time.monotonic() - started:.2f}s", flush=True)
    try:
        size = 1024
        source, target = (c.c_float * size)(), (c.c_float * size)()
        intensity = c.c_float(1.0)
        descriptor.connect(instance, 0, source)
        descriptor.connect(instance, 1, target)
        descriptor.connect(instance, 2, c.pointer(intensity))
        rng = random.Random(47)
        levels = {}
        for strength in (0.0, 1.0, 0.0):
            intensity.value = strength
            descriptor.activate(instance)
            total = 0.0
            peak_ms = 0.0
            started = time.monotonic()
            for frame in range(240):
                for i in range(size):
                    source[i] = rng.uniform(-0.05, 0.05)
                tick = time.monotonic()
                descriptor.run(instance, size)
                peak_ms = max(peak_ms, (time.monotonic() - tick) * 1000)
                if not all(math.isfinite(x) for x in target):
                    raise RuntimeError("Nonfinite processed audio")
                if frame >= 120:
                    total += sum(x * x for x in target)
            rms = math.sqrt(total / (120 * size))
            print(f"intensity={strength:.0%}, RMS={rms:.6f}, processing={time.monotonic()-started:.3f}s, max callback={peak_ms:.2f}ms", flush=True)
            if strength == 0 and rms < 0.001:
                raise RuntimeError("Bypass produced silence; runtime may have failed")
            levels[strength] = rms
        if levels[1.0] >= levels[0.0] * 0.8:
            raise RuntimeError("Noise attenuation did not respond to intensity")
        print("PASS: live intensity changes, finite output, noise reduction, re-enabled bypass")
    finally:
        descriptor.cleanup(instance)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("plugin")
    probe(parser.parse_args().plugin)
