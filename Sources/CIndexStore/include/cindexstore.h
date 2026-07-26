/*
 * cindexstore.h — hand-declared subset of libIndexStore's C API, as FUNCTION
 * POINTER typedefs.
 *
 * The toolchain ships `libIndexStore.dylib` but NOT its header
 * (`indexstore/indexstore.h`), so we declare exactly the entry points SwiftProf
 * consumes. Every symbol below was verified present in
 *   $(xcrun --find swift)/../../lib/libIndexStore.dylib
 * via `nm -gU`. The signatures match the stable libIndexStore C ABI (format
 * version 5; asserted at runtime by `indexstore_format_version`).
 *
 * These are TYPEDEFS, not extern declarations: the dylib is NOT linked at build
 * time. `IndexStoreDylib.swift` dlopens it at first use (path resolved via
 * `xcrun` at RUNTIME) and dlsyms each entry point into these pointer types —
 * so the produced binary launches on machines with no Xcode at all; only
 * actually USING the index layer (--index-store-path) requires a toolchain.
 * Each typedef is `fp_` + the exact dylib symbol name it must be dlsym'd from.
 *
 * Only the `*_apply_f` callback variants are declared — they take a plain C
 * function pointer + a `void *` context, so Swift can pass `@convention(c)`
 * closures with NO Objective-C block-interop dependency (the `*_apply` block
 * variants are deliberately omitted).
 *
 * Opaque handles are `void *`; libIndexStore owns their lifetime via the
 * matching `*_dispose` calls.
 */
#ifndef CINDEXSTORE_H
#define CINDEXSTORE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *indexstore_t;
typedef void *indexstore_error_t;
typedef void *indexstore_unit_reader_t;
typedef void *indexstore_record_reader_t;
typedef void *indexstore_symbol_t;
typedef void *indexstore_occurrence_t;
typedef void *indexstore_unit_dependency_t;

/* Non-owning {pointer,length} view into a UTF-8 buffer owned by libIndexStore. */
typedef struct {
  const char *data;
  size_t length;
} indexstore_string_ref_t;

typedef enum {
  INDEXSTORE_UNIT_DEPENDENCY_UNIT = 1,
  INDEXSTORE_UNIT_DEPENDENCY_RECORD = 2,
  INDEXSTORE_UNIT_DEPENDENCY_FILE = 3,
} indexstore_unit_dependency_kind_t;

/* Symbol-role bitmask (subset). Returned by indexstore_occurrence_get_roles. */
typedef uint64_t indexstore_symbol_role_t;
enum {
  INDEXSTORE_SYMBOL_ROLE_DECLARATION = 1 << 0,
  INDEXSTORE_SYMBOL_ROLE_DEFINITION  = 1 << 1,
  INDEXSTORE_SYMBOL_ROLE_REFERENCE   = 1 << 2,
};

typedef uint64_t indexstore_symbol_kind_t;

/* --- applier callbacks (passed BY SwiftProf INTO libIndexStore) ----------- */

typedef bool (*indexstore_units_applier_t)(void *context,
                                           indexstore_string_ref_t unit_name);
typedef bool (*indexstore_dependencies_applier_t)(void *context,
                                                  indexstore_unit_dependency_t dep);
typedef bool (*indexstore_occurrences_applier_t)(void *context,
                                                 indexstore_occurrence_t occ);

/* --- store --------------------------------------------------------------- */

typedef unsigned (*fp_indexstore_format_version)(void);

typedef indexstore_t (*fp_indexstore_store_create)(const char *store_path,
                                                   indexstore_error_t *error);
typedef void (*fp_indexstore_store_dispose)(indexstore_t store);

typedef const char *(*fp_indexstore_error_get_description)(indexstore_error_t error);
typedef void (*fp_indexstore_error_dispose)(indexstore_error_t error);

typedef bool (*fp_indexstore_store_units_apply_f)(
    indexstore_t store, unsigned sorted, void *context,
    indexstore_units_applier_t applier);

/* --- unit reader --------------------------------------------------------- */

typedef indexstore_unit_reader_t (*fp_indexstore_unit_reader_create)(
    indexstore_t store, const char *unit_name, indexstore_error_t *error);
typedef void (*fp_indexstore_unit_reader_dispose)(indexstore_unit_reader_t reader);

typedef indexstore_string_ref_t (*fp_indexstore_unit_reader_get_module_name)(
    indexstore_unit_reader_t reader);
typedef indexstore_string_ref_t (*fp_indexstore_unit_reader_get_main_file)(
    indexstore_unit_reader_t reader);
/* NOTE: libIndexStore's `indexstore_unit_reader_get_modification_time` is
 * deliberately NOT declared here. It returns a composite (not int64) whose exact
 * ABI we don't hand-declare safely — a wrong return type silently corrupts the
 * heap (learned the hard way). Staleness uses the unit file's filesystem mtime
 * instead (USRIndex.unitFileModTime). Restore a real declaration only from a
 * ground-truth indexstore.h, never a guess. */

typedef bool (*fp_indexstore_unit_reader_dependencies_apply_f)(
    indexstore_unit_reader_t reader, void *context,
    indexstore_dependencies_applier_t applier);

typedef indexstore_unit_dependency_kind_t (*fp_indexstore_unit_dependency_get_kind)(
    indexstore_unit_dependency_t dep);
typedef indexstore_string_ref_t (*fp_indexstore_unit_dependency_get_name)(
    indexstore_unit_dependency_t dep);
typedef indexstore_string_ref_t (*fp_indexstore_unit_dependency_get_filepath)(
    indexstore_unit_dependency_t dep);
typedef indexstore_string_ref_t (*fp_indexstore_unit_dependency_get_modulename)(
    indexstore_unit_dependency_t dep);

/* --- record reader ------------------------------------------------------- */

typedef indexstore_record_reader_t (*fp_indexstore_record_reader_create)(
    indexstore_t store, const char *record_name, indexstore_error_t *error);
typedef void (*fp_indexstore_record_reader_dispose)(indexstore_record_reader_t reader);

typedef bool (*fp_indexstore_record_reader_occurrences_apply_f)(
    indexstore_record_reader_t reader, void *context,
    indexstore_occurrences_applier_t applier);

/* --- occurrence / symbol ------------------------------------------------- */

typedef indexstore_symbol_t (*fp_indexstore_occurrence_get_symbol)(
    indexstore_occurrence_t occ);
typedef indexstore_symbol_role_t (*fp_indexstore_occurrence_get_roles)(
    indexstore_occurrence_t occ);
typedef void (*fp_indexstore_occurrence_get_line_col)(indexstore_occurrence_t occ,
                                                      unsigned *line,
                                                      unsigned *column);

typedef indexstore_string_ref_t (*fp_indexstore_symbol_get_usr)(
    indexstore_symbol_t symbol);
typedef indexstore_string_ref_t (*fp_indexstore_symbol_get_name)(
    indexstore_symbol_t symbol);
typedef indexstore_symbol_kind_t (*fp_indexstore_symbol_get_kind)(
    indexstore_symbol_t symbol);

#ifdef __cplusplus
}
#endif

#endif /* CINDEXSTORE_H */
