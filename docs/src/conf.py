"""Configuration file for Sphinx."""

import re
from pathlib import Path

project = "SKA Low CBF Firmware CORR"
copyright = "2019-2023, David Humphrey, Norbert Abel, Leon Heimstra, Andrew Brown"
author = "David Humphrey, Norbert Abel, Leon Heimstra, Andrew Brown"
# Version comes from the repo's .release file (maintained by `make bump-*-release`)
version = release = re.search(
    r"^release=(.+)$",
    (Path(__file__).parents[2] / ".release").read_text(),
    re.MULTILINE,
).group(1)

html_theme = "ska_ser_sphinx_theme"
pygments_style = "sphinx"
