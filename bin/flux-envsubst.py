#!/usr/bin/env python3
"""Local stand-in for Flux post-build variable substitution.

Reads multi-document YAML (kustomize build output) on stdin and writes it to
stdout with ${VAR} placeholders filled in, following kustomize-controller with
StrictPostBuildSubstitutions=true (enabled in flux/modules/flux-system):

  * Only the braced form is substituted: ${VAR}, ${VAR:=default},
    ${VAR:-default}, ${VAR=default}, ${VAR-default}. Bare $VAR, $1 and
    $(VAR) are left alone.
  * $${VAR} is an escape and renders as a literal ${VAR}.
  * A resource labelled or annotated
    kustomize.toolkit.fluxcd.io/substitute: disabled passes through untouched.
  * An undefined variable without a default is an error.

Other bash-style expressions (${#VAR}, ${VAR/a/b}, ...) are rejected, because
nothing in this repository uses them.

Usage: flux-envsubst.py VARS_FILE < rendered.yaml > substituted.yaml

VARS_FILE holds KEY=VALUE lines, as accepted by
`kubectl create configmap --from-env-file`: blank lines and # comments are
ignored and values are taken literally.
"""

import re
import sys

NAME = re.compile(r"^[_A-Za-z][_A-Za-z0-9]*$")
EXPRESSION = re.compile(r"\$\$\{|\$\{([^}]*)\}")
WITH_DEFAULT = re.compile(r"^([_A-Za-z][_A-Za-z0-9]*)(:?[-=])(.*)$", re.S)
DISABLED = re.compile(
    r"^\s+kustomize\.toolkit\.fluxcd\.io/substitute:\s*[\"']?disabled[\"']?\s*$",
    re.M,
)
DOCUMENT_SEPARATOR = re.compile(r"(?m)^---[ \t]*\n")


def load_vars(path):
    variables = {}
    with open(path, encoding="utf-8") as handle:
        for number, raw in enumerate(handle, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            key, separator, value = line.partition("=")
            if not separator or not NAME.match(key):
                sys.exit(f"{path}:{number}: expected KEY=VALUE, got {line!r}")
            variables[key] = value
    return variables


def describe(document):
    kind = re.search(r"(?m)^kind:\s*(\S+)", document)
    name = re.search(r"(?m)^  name:\s*(\S+)", document)
    return f"{kind.group(1) if kind else '?'}/{name.group(1) if name else '?'}"


def substitute(document, variables):
    def replace(match):
        if match.group(0) == "$${":
            return "${"
        expression = match.group(1)
        if NAME.match(expression):
            if expression not in variables:
                raise KeyError(f"variable {expression} is not defined")
            return variables[expression]
        with_default = WITH_DEFAULT.match(expression)
        if with_default:
            name, operator, default = with_default.groups()
            value = variables.get(name)
            if value is None or (operator.startswith(":") and value == ""):
                return default
            return value
        raise KeyError(f"unsupported expression ${{{expression}}}")

    return EXPRESSION.sub(replace, document)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.split("\n\n")[0] + "\nusage: flux-envsubst.py VARS_FILE")
    variables = load_vars(sys.argv[1])
    documents = DOCUMENT_SEPARATOR.split(sys.stdin.read())
    output = []
    for document in documents:
        if DISABLED.search(document):
            output.append(document)
            continue
        try:
            output.append(substitute(document, variables))
        except KeyError as error:
            sys.exit(f"flux-envsubst: {describe(document)}: {error.args[0]}")
    sys.stdout.write("---\n".join(output))


if __name__ == "__main__":
    main()
