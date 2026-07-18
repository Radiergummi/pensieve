// sqlite-vec vendored version: v0.1.9 (commit e9f598abfa0c06b328d8fe5da9c3760cce74be10)
// Source: https://github.com/asg017/sqlite-vec/releases/tag/v0.1.9
#include <stddef.h>
#include <sqlite3.h>
// sqlite-vec's init entry point (defined in sqlite-vec.c)
extern int sqlite3_vec_init(sqlite3 *db, char **pzErrMsg, const sqlite3_api_routines *pApi);

// Register sqlite-vec so every subsequent connection in this process loads vec0.
//
// NOTE (spike finding): Apple's system libsqlite3 marks sqlite3_auto_extension()
// API_DEPRECATED("Process-global auto extensions are not supported on Apple
// platforms") and it fails at runtime with SQLITE_MISUSE (21) — confirmed on this
// machine. This entry point is kept for portability/documentation, but callers on
// Apple platforms must use pensieve_sqlite_vec_init_connection() below instead,
// invoked per-connection via GRDB's Configuration.prepareDatabase.
int pensieve_sqlite_vec_register(void) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  return sqlite3_auto_extension((void (*)(void))sqlite3_vec_init);
#pragma clang diagnostic pop
}

// Register sqlite-vec directly on one already-open connection. This is the
// working path on Apple platforms (see note above); call it from
// GRDB's Configuration.prepareDatabase(_:) with db.sqliteConnection.
int pensieve_sqlite_vec_init_connection(void *db) {
  char *errmsg = NULL;
  int rc = sqlite3_vec_init((sqlite3 *)db, &errmsg, NULL);
  if (errmsg != NULL) {
    sqlite3_free(errmsg);
  }
  return rc;
}
