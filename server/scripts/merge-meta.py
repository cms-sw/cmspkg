#!/usr/bin/env python
from sys import argv
from cmspkg_utils import merge_meta
merge_meta(argv[1], argv[2], argv[1])
