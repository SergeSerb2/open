"""Restore typed preferences after the owned App exits, without putting values in argv."""
import ctypes
import plistlib


def write_collection(key, value, domain=None):
    domain = domain or __import__('prefs_domain').domain()
    # A supported 1000-host preference can exceed exec's argument limit as XML.
    # Use the same per-key preferences API as UserDefaults, with in-process data.
    cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    ptr = ctypes.c_void_p
    cf.CFDataCreate.argtypes = [ptr, ctypes.c_char_p, ctypes.c_long]
    cf.CFDataCreate.restype = ptr
    cf.CFPropertyListCreateWithData.argtypes = [ptr, ptr, ctypes.c_ulong, ptr, ptr]
    cf.CFPropertyListCreateWithData.restype = ptr
    cf.CFStringCreateWithCString.argtypes = [ptr, ctypes.c_char_p, ctypes.c_uint32]
    cf.CFStringCreateWithCString.restype = ptr
    cf.CFPreferencesSetAppValue.argtypes = [ptr, ptr, ptr]
    cf.CFPreferencesSetAppValue.restype = None
    cf.CFPreferencesAppSynchronize.argtypes = [ptr]
    cf.CFPreferencesAppSynchronize.restype = ctypes.c_bool
    cf.CFRelease.argtypes = [ptr]
    cf.CFRelease.restype = None
    encoded = plistlib.dumps(value, fmt=plistlib.FMT_BINARY)
    data = cf.CFDataCreate(None, encoded, len(encoded))
    objects = [data]
    try:
        item = cf.CFPropertyListCreateWithData(None, data, 0, None, None) if data else None
        name = cf.CFStringCreateWithCString(None, key.encode(), 0x08000100)
        target = cf.CFStringCreateWithCString(None, domain.encode(), 0x08000100)
        objects += [item, name, target]
        if not all(objects):
            raise RuntimeError('Could not decode collection preference ' + key)
        cf.CFPreferencesSetAppValue(name, item, target)
        if not cf.CFPreferencesAppSynchronize(target):
            raise RuntimeError('Could not restore collection preference ' + key)
    finally:
        for obj in reversed(objects):
            if obj:
                cf.CFRelease(obj)
