#!/usr/bin/env python3
# MACDART port of runtime/tools/gen_library_src_paths.py (originally Python 2).
#
# Emits a C++ source file that embeds a set of Dart library source files as
# byte arrays, plus a NULL-terminated table mapping
#   [library-uri, main-path, main-array, part-name, part-path, part-array, ...]
# consumed by dart::Bootstrap / dart::bin::Builtin at VM init in the
# "nosnapshot" configuration (core libs compiled from embedded source).
#
# Behavioural parity with upstream, with Python 3 fixes:
#   * bytes iteration yields ints in Py3 (no ord()).
#   * `except E as e` syntax.
#   * `utils.GuessOS()` import dropped (was computed but unused).
from __future__ import annotations

import argparse
import os
import sys


def make_string(input_file: str, var_name: str) -> str:
    result = "static const char " + var_name + "[] = {\n "
    with open(input_file, "rb") as fh:
        data = fh.read()
    line_counter = 0
    for byte in data:  # Py3: iterating bytes yields ints
        result += "'\\x%02x', " % byte
        line_counter += 1
        if line_counter == 19:
            result += "\n "
            line_counter = 0
    result += "0};\n"
    return result


def make_source_arrays(in_files: list[str]) -> str:
    result = ""
    file_count = 0
    for string_file in in_files:
        if string_file.endswith(".dart"):
            file_count += 1
            result += make_string(string_file, "source_array_" + str(file_count))
    return result


def make_file(output_file, input_cc_file, include, var_name, lib_name, in_files) -> bool:
    part_index = []
    with open(input_cc_file) as fh:
        text = fh.read()
    text = text.replace("{{SOURCE_ARRAYS}}", make_source_arrays(in_files))
    text = text.replace("{{INCLUDE}}", include)
    text = text.replace("{{VAR_NAME}}", var_name)

    main_file_found = False
    file_count = 0
    for string_file in in_files:
        if not string_file.endswith(".dart"):
            continue
        file_count += 1
        if not main_file_found:
            with open(string_file) as inpt:
                for line in inpt:
                    # The file carrying the `library` tag is the main file.
                    if line.startswith("library "):
                        main_file_found = True
                        text = text.replace(
                            "{{LIBRARY_SOURCE_MAP}}",
                            ' "' + lib_name + '",\n "'
                            + os.path.abspath(string_file).replace("\\", "\\\\")
                            + '",\n' + " source_array_" + str(file_count) + ",\n",
                        )
            if main_file_found:
                continue
        part_index.append(' "' + os.path.basename(string_file).replace("\\", "\\\\") + '",\n')
        part_index.append(' "' + os.path.abspath(string_file).replace("\\", "\\\\") + '",\n')
        part_index.append(" source_array_" + str(file_count) + ",\n\n")

    # If no `library` tag was found, collapse the placeholder to empty.
    text = text.replace("{{LIBRARY_SOURCE_MAP}}", "")
    text = text.replace("{{PART_SOURCE_MAP}}", "".join(part_index))

    with open(output_file, "w") as out:
        out.write(text)
    return True


def main(argv) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--output", required=True)
    p.add_argument("--input_cc", required=True)
    p.add_argument("--include", required=True)
    p.add_argument("--library_name", required=True)
    p.add_argument("--var_name", required=True)
    p.add_argument("sources", nargs="+")
    args = p.parse_args(argv[1:])
    try:
        ok = make_file(args.output, args.input_cc, args.include,
                       args.var_name, args.library_name, args.sources)
        return 0 if ok else -1
    except Exception as e:  # noqa: BLE001 - match upstream's catch-all
        sys.stderr.write("gen_library_src_paths.py exception\n")
        sys.stderr.write(str(e) + "\n")
        return -1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
