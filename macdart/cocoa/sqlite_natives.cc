// MACDART workspace — a minimal SQLite binding (libsqlite3, shipped with macOS).
// The workspace "image": the user app's declarations live here (source of truth),
// loaded on top of the VM snapshot (the "world") at boot, written by Accept, and
// re-read after a watchdog respawn. Parameterised (bind) queries only — never
// string-concatenated SQL. Registered via the dart:cocoa resolver. See
// WORKSPACE_PLAN.md.
#include <sqlite3.h>
#include <stdio.h>
#include <string>
#include <vector>

#include "include/dart_api.h"

namespace dart {
namespace bin {

// _sqlOpen(String path) -> int (sqlite3* as an int handle; 0 on failure).
void Sqlite_open(Dart_NativeArguments args) {
  const char* path = NULL;
  Dart_StringToCString(Dart_GetNativeArgument(args, 0), &path);
  sqlite3* db = NULL;
  if (sqlite3_open(path, &db) != SQLITE_OK) {
    if (db != NULL) sqlite3_close(db);
    db = NULL;
  }
  Dart_SetReturnValue(args, Dart_NewInteger((int64_t)db));
}

// _sqlClose(int db).
void Sqlite_close(Dart_NativeArguments args) {
  int64_t h = 0;
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 0), &h);
  if (h != 0) sqlite3_close((sqlite3*)h);
}

// Bind a Dart List<String> of params to positional ?1..?N (null-safe).
static void BindParams(sqlite3_stmt* stmt, Dart_Handle params) {
  if (Dart_IsNull(params)) return;
  intptr_t n = 0;
  if (Dart_IsError(Dart_ListLength(params, &n))) return;
  for (intptr_t i = 0; i < n; i++) {
    Dart_Handle e = Dart_ListGetAt(params, i);
    const char* s = NULL;
    if (!Dart_IsError(Dart_StringToCString(e, &s)) && s != NULL) {
      sqlite3_bind_text(stmt, (int)(i + 1), s, -1, SQLITE_TRANSIENT);
    } else {
      sqlite3_bind_null(stmt, (int)(i + 1));
    }
  }
}

// _sqlExec(int db, String sql, List params) -> String ("" ok, else "ERR: msg").
// For statements that return no rows (CREATE/INSERT/UPDATE/DELETE).
void Sqlite_exec(Dart_NativeArguments args) {
  int64_t h = 0;
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 0), &h);
  sqlite3* db = (sqlite3*)h;
  const char* sql = NULL;
  Dart_StringToCString(Dart_GetNativeArgument(args, 1), &sql);
  Dart_Handle params = Dart_GetNativeArgument(args, 2);

  sqlite3_stmt* stmt = NULL;
  if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) {
    char buf[512];
    snprintf(buf, sizeof(buf), "ERR: %s", sqlite3_errmsg(db));
    Dart_SetReturnValue(args, Dart_NewStringFromCString(buf));
    return;
  }
  BindParams(stmt, params);
  int rc = sqlite3_step(stmt);
  sqlite3_finalize(stmt);
  if (rc != SQLITE_DONE && rc != SQLITE_ROW) {
    char buf[512];
    snprintf(buf, sizeof(buf), "ERR: %s", sqlite3_errmsg(db));
    Dart_SetReturnValue(args, Dart_NewStringFromCString(buf));
    return;
  }
  Dart_SetReturnValue(args, Dart_NewStringFromCString(""));
}

// _sqlQuery(int db, String sql, List params) -> List<List<String>> rows (null on
// prepare error). Each cell is text (NULL -> "").
void Sqlite_query(Dart_NativeArguments args) {
  int64_t h = 0;
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, 0), &h);
  sqlite3* db = (sqlite3*)h;
  const char* sql = NULL;
  Dart_StringToCString(Dart_GetNativeArgument(args, 1), &sql);
  Dart_Handle params = Dart_GetNativeArgument(args, 2);

  sqlite3_stmt* stmt = NULL;
  if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) {
    Dart_SetReturnValue(args, Dart_Null());
    return;
  }
  BindParams(stmt, params);

  std::vector<std::vector<std::string> > rows;
  while (sqlite3_step(stmt) == SQLITE_ROW) {
    int ncol = sqlite3_column_count(stmt);
    std::vector<std::string> row;
    for (int c = 0; c < ncol; c++) {
      const unsigned char* t = sqlite3_column_text(stmt, c);
      row.push_back(t != NULL ? std::string((const char*)t) : std::string());
    }
    rows.push_back(row);
  }
  sqlite3_finalize(stmt);

  Dart_Handle result = Dart_NewList((intptr_t)rows.size());
  for (size_t i = 0; i < rows.size(); i++) {
    Dart_Handle drow = Dart_NewList((intptr_t)rows[i].size());
    for (size_t c = 0; c < rows[i].size(); c++) {
      Dart_ListSetAt(drow, (intptr_t)c, Dart_NewStringFromCString(rows[i][c].c_str()));
    }
    Dart_ListSetAt(result, (intptr_t)i, drow);
  }
  Dart_SetReturnValue(args, result);
}

}  // namespace bin
}  // namespace dart
