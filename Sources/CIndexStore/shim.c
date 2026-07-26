/* Header-only shim: all declarations live in include/cindexstore.h as function
 * pointer TYPEDEFS — nothing links against libIndexStore.dylib at build time;
 * IndexStoreDylib.swift dlopens it at first use. This translation unit exists
 * only because SwiftPM requires a C target to have at least one source file. */
#include "cindexstore.h"
