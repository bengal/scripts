#!/bin/sh

time make C=1 CC="ccache gcc" -j4 binrpm-pkg
