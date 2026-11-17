"""Small Darwin capacity observation; no queues, subprocesses or persistent cache.

Call sample() only outside execution/admission locks. The load average remains
diagnostic on Darwin; other platforms retain their existing load policy.
"""
from __future__ import annotations

import ctypes
from dataclasses import dataclass
import math
import sys
import time

MIN_IDLE = 0.20
SAMPLE_SECONDS = 1.0
MAX_INTERVAL = 2.0
MAX_AGE = 2.0
PRESSURES = {1: "normal", 2: "warning", 4: "critical"}


def is_darwin():
    return sys.platform == "darwin"


@dataclass(frozen=True)
class Reading:
    ticks: tuple[int, int, int, int]
    processors: int
    pressure: int


@dataclass(frozen=True)
class Sample:
    idle_fraction: float
    processors: int
    pressure: int
    measured_at: float


class SampleExpired(Exception):
    """A valid past-age sample may be measured again outside execution locks."""


def _check_age(measured_at, current):
    if not _number(current) or current < measured_at:
        return False
    if current - measured_at > MAX_AGE:
        raise SampleExpired()
    return True


def _number(value):
    return type(value) in (int, float) and -2**53 <= value <= 2**53 and math.isfinite(value)


def _reading(value):
    return (isinstance(value, Reading) and type(value.ticks) is tuple and len(value.ticks) == 4
            and all(type(n) is int and 0 <= n <= 0xffffffff for n in value.ticks)
            and type(value.processors) is int and 0 < value.processors <= 65536
            and type(value.pressure) is int and value.pressure in PRESSURES)


def from_readings(first, last, started, ended):
    """Reject ambiguous counters/intervals rather than invent idle capacity."""
    if (not _reading(first) or not _reading(last) or first.processors != last.processors
            or not _number(started) or started < 0 or not _number(ended)
            or not SAMPLE_SECONDS <= ended - started <= MAX_INTERVAL):
        return None
    delta = [b - a for a, b in zip(first.ticks, last.ticks)]
    if min(delta) < 0 or sum(delta) <= 0:
        return None
    # Preserve pressure seen at either endpoint, even if it recovered meanwhile.
    pressure = max(first.pressure, last.pressure)
    return Sample(delta[2] / sum(delta), last.processors, pressure, ended)


class DarwinProbe:
    """Fixed-size public Mach reads and the read-only XNU pressure sysctl.

    The pressure key is not guaranteed on every OS release. Missing/unknown
    values are unavailable, never normal. No shell or process enumeration.
    """
    def __init__(self):
        self.lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        self.lib.sysctlbyname.argtypes = [ctypes.c_char_p, ctypes.c_void_p,
                                          ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
        self.lib.sysctlbyname.restype = ctypes.c_int
        self.lib.mach_host_self.argtypes = []
        self.lib.mach_host_self.restype = ctypes.c_uint32
        self.lib.host_statistics.argtypes = [ctypes.c_uint32, ctypes.c_int,
                                            ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
        self.lib.host_statistics.restype = ctypes.c_int
        self.lib.mach_port_deallocate.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
        self.lib.mach_port_deallocate.restype = ctypes.c_int

    def integer(self, name):
        value = ctypes.c_int32()
        size = ctypes.c_size_t(ctypes.sizeof(value))
        if self.lib.sysctlbyname(name, ctypes.byref(value), ctypes.byref(size), None, 0) != 0 or size.value != 4:
            raise OSError("resource_sysctl_unavailable")
        return value.value

    def pressure(self):
        value = self.integer(b"kern.memorystatus_vm_pressure_level")
        if value not in PRESSURES:
            raise ValueError("resource_pressure_unknown")
        return value

    def processors(self):
        value = self.integer(b"hw.activecpu")
        if not 0 < value <= 65536:
            raise ValueError("resource_cpu_count_invalid")
        return value

    def read(self):
        ticks = (ctypes.c_uint32 * 4)()
        count = ctypes.c_uint32(4)
        host = self.lib.mach_host_self()
        if not host:
            raise OSError("resource_host_unavailable")
        try:
            # HOST_CPU_LOAD_INFO=3; USER/SYSTEM/IDLE/NICE are four uint32 ticks.
            if self.lib.host_statistics(host, 3, ticks, ctypes.byref(count)) != 0 or count.value != 4:
                raise OSError("resource_cpu_unavailable")
        finally:
            task = ctypes.c_uint32.in_dll(self.lib, "mach_task_self_").value
            self.lib.mach_port_deallocate(task, host)
        return Reading(tuple(ticks), self.processors(), self.pressure())


def sample(*, probe=None, clock=None, sleep=None):
    """One interval, no retries. A late syscall return is discarded, not timed out."""
    clock, sleep = clock or time.monotonic, sleep or time.sleep
    try:
        started = clock()
        probe = probe or DarwinProbe()
        first = probe.read()
        sleep(SAMPLE_SECONDS)
        last = probe.read()
        return from_readings(first, last, started, clock())
    except (OSError, ValueError, TypeError, OverflowError, AttributeError):
        return None


def decision(observation, *, probe=None, clock=None):
    """Fast final validation; only valid past-age samples raise SampleExpired."""
    try:
        current = (clock or time.monotonic)()
        if (not isinstance(observation, Sample) or not _number(observation.idle_fraction)
                or not 0 <= observation.idle_fraction <= 1 or not _number(observation.measured_at)
                or observation.measured_at < 0
                or type(observation.processors) is not int or not 0 < observation.processors <= 65536
                or type(observation.pressure) is not int or observation.pressure not in PRESSURES):
            return "resource_unavailable", {}
        if not _check_age(observation.measured_at, current):
            return "resource_unavailable", {}
        probe = probe or DarwinProbe()
        processors, pressure = probe.processors(), probe.pressure()
        if (type(processors) is not int or processors != observation.processors
                or type(pressure) is not int or pressure not in PRESSURES):
            return "resource_unavailable", {}
        # Include the time spent in final OS reads in the freshness check.
        if not _check_age(observation.measured_at, (clock or time.monotonic)()):
            return "resource_unavailable", {}
        pressure = max(pressure, observation.pressure)
        fields = {"cpu_idle_fraction": observation.idle_fraction, "memory_pressure": PRESSURES[pressure]}
        if pressure != 1:
            return "memory_pressure", fields
        if observation.idle_fraction < MIN_IDLE:
            return "cpu_pressure", fields
        return None, fields
    except (OSError, ValueError, TypeError, OverflowError, AttributeError):
        return "resource_unavailable", {}
