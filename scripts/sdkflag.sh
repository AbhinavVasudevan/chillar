# Sourced by build.sh and test.sh. Sets SDKFLAG to an SDK this swiftc can read: the default, or
# (when the Command Line Tools ship an SDK newer than their compiler) the newest older SDK that works.
# Probed with an empty program so real compile errors in the sources are always shown.
PROBE=$(mktemp -d)
echo 'print("")' > "$PROBE/p.swift"
SDKFLAG=
if ! swiftc -parse-as-library "$PROBE/p.swift" -o "$PROBE/p" 2>/dev/null; then
  for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -r -V); do
    if swiftc -sdk "$sdk" "$PROBE/p.swift" -o "$PROBE/p" 2>/dev/null; then SDKFLAG="-sdk $sdk"; echo "Using $(basename "$sdk")"; break; fi
  done
fi
rm -rf "$PROBE"
