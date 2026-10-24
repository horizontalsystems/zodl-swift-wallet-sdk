#!/usr/bin/env python3
"""Run the CI producer from its tooling checkout, regardless of the current directory."""
import sys

from sdk_release_build import main


if __name__ == "__main__":
    sys.exit(main())
