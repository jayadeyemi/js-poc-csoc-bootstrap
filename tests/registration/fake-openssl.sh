#!/usr/bin/env sh
set -eu

case " $* " in
  *" genpkey "*|*" req "*)
    output=
    previous=
    for argument in "$@"; do
      if [ "$previous" = -out ]; then output=$argument; break; fi
      previous=$argument
    done
    [ -n "$output" ] && printf 'fake-key-or-request' >"$output"
    ;;
  *" x509 "*" -checkend "*)
    [ "${FAKE_CERT_EXPIRED:-false}" != true ]
    ;;
  *" x509 "*" -enddate "*)
    echo 'notAfter=Nov 26 00:00:00 2026 GMT'
    ;;
  *)
    echo "unsupported fake openssl command: $*" >&2
    exit 1
    ;;
esac
