//
// c extensions, for revo
// build: make extension   (produces extension.dylib on mac)
//
// the shared lib exports revo_bindings which cload() picks up
//

#include "revo.h"
#include <regex.h>
#include <string.h>

/// > greet(name: string) -> string
static void greet_fn(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  if (argc < 1 || !revo_is_string(argv[0])) {
    *out_result = revo_nil();
    return;
  }

  const char *name = (const char *)(uintptr_t)argv[0].value;
  size_t name_len = strlen(name);

  // build "hello, <name>!" and intern it
  char buf[256];
  memcpy(buf, "hello, ", 7);
  memcpy(buf + 7, name, name_len);
  buf[7 + name_len] = '!';

  uint64_t sid = revo_intern(vm, (uint64_t)(uintptr_t)buf, 7 + name_len + 1);
  *out_result = R_STRING(sid);
}

/// > add(a: number, b: number) -> number
static void add_fn(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  (void)vm;
  if (argc < 2 || !revo_is_number(argv[0]) || !revo_is_number(argv[1])) {
    *out_result = revo_nil();
    return;
  }
  *out_result = revo_num(revo_num_value(argv[0]) + revo_num_value(argv[1]));
}

/// > echo(s: string) -> string
static void echo_fn(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  if (argc < 1 || !revo_is_string(argv[0])) {
    *out_result = revo_nil();
    return;
  }
  // must re-intern: argv[0].value is a pointer, not a string_id
  const char *str = (const char *)(uintptr_t)argv[0].value;
  uint64_t sid = revo_intern(vm, (uint64_t)(uintptr_t)str, strlen(str));
  *out_result = R_STRING(sid);
}

/// > strlen(s: string) -> number
static void strlen_fn(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  (void)vm;
  if (argc < 1 || !revo_is_string(argv[0])) {
    *out_result = revo_num(0);
    return;
  }
  const char *str = (const char *)(uintptr_t)argv[0].value;
  *out_result = revo_num((double)strlen(str));
}

/// > typ(x) -> number
/// returns RevoType tag: 0=number, 1=string, 2=atom, etc
static void typ_fn(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  (void)vm;
  if (argc < 1) {
    *out_result = revo_nil();
    return;
  }
  *out_result = revo_num((double)argv[0].tag);
}

/// > regex(pattern: string, text: string) -> bool
static void regex_fn(void *vm, size_t argc, RevoData *argv, RevoData *out_result) {
  (void)vm;
  if (argc < 2 || !revo_is_string(argv[0]) || !revo_is_string(argv[1])) {
    *out_result = revo_num(0);
    return;
  }

  const char *pattern = (const char *)(uintptr_t)argv[0].value;
  const char *text = (const char *)(uintptr_t)argv[1].value;

  regex_t regex;
  if (regcomp(&regex, pattern, REG_EXTENDED | REG_NOSUB) != 0) {
    regfree(&regex);
    *out_result = revo_num(0);
    return;
  }

  int match = regexec(&regex, text, 0, NULL, 0);
  regfree(&regex);

  *out_result = revo_bool(match == 0);
}

__attribute__((visibility("default"))) const RevoBinding revo_bindings[] = {
  {"greet", greet_fn},
  {"add", add_fn},
  {"echo", echo_fn},
  {"strlen", strlen_fn},
  {"typ", typ_fn},
  {"regex", regex_fn},
  {NULL, NULL},
};
