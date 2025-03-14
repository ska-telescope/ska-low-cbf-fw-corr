# -*- coding: utf-8 -*-
#
"""
Standard sphinx config file.
"""

import sys
import os
import typing

# WORKAROUND: https://github.com/sphinx-doc/sphinx/issues/9243
import sphinx.builders.linkcheck
import sphinx.builders.html
import sphinx.builders.latex
import sphinx.builders.texinfo
import sphinx.builders.text
import sphinx.ext.autodoc

# This is an elaborate hack to insert write property into _all_
# mock decorators. It is needed for getting @attribute to build
# in mocked out tango.server
# see https://github.com/sphinx-doc/sphinx/issues/6709
from sphinx.ext.autodoc.mock import _MockObject


def call_mock(self, *args, **kw):
    from types import FunctionType, MethodType

    if args and type(args[0]) in [type, FunctionType, MethodType]:
        # Appears to be a decorator, pass through unchanged
        args[0].write = lambda x: x
        return args[0]
    return self


_MockObject.__call__ = call_mock
# hack end


def setup(app):
    app.add_css_file('css/custom.css')
    app.add_js_file('js/gitlab.js')

# -- General configuration ------------------------------------------------

# If your documentation needs a minimal Sphinx version, state it here.
#needs_sphinx = '1.0'

# Add any Sphinx extension module names here, as strings. They can be
# extensions coming with Sphinx (named 'sphinx.ext.*') or your custom
# ones.
extensions = [
    'sphinx.ext.autodoc',
    'sphinx.ext.napoleon',
    'sphinx.ext.doctest',
    'sphinx.ext.intersphinx',
    'sphinx.ext.todo',
    'sphinx.ext.coverage',
    'sphinx.ext.mathjax',
    'sphinx.ext.ifconfig',
    'sphinx.ext.viewcode',
    'sphinx.ext.githubpages',
    'recommonmark'
]

# Add any paths that contain templates here, relative to this directory.
templates_path = []

# The suffix(es) of source filenames.
# You can specify multiple suffix as a list of string:
#
source_suffix = ['.rst', '.md']

# The master toctree document.
master_doc = 'index'

# General information about the project.
project = u'SKA Low CBF Firmware CORR'
copyright = u'2019-2023, David Humphrey, Norbert Abel, Leon Heimstra, Andrew Brown'
author = u'David Humphrey, Norbert Abel, Leon Heimstra, Andrew Brown'

# The version info for the project you're documenting, acts as replacement for
# |version| and |release|, also used in various other places throughout the
# built documents.
#
# The short X.Y version.
version = u'0.0.2'
# The full version, including alpha/beta/rc tags.
release = u'0.0.2'

# The language for content autogenerated by Sphinx. Refer to documentation
# for a list of supported languages.
#
# This is also used if you do content translation via gettext catalogs.
# Usually you set "language" from the command line for these cases.
language = 'En-en'

# List of patterns, relative to source directory, that match files and
# directories to ignore when looking for source files.
exclude_patterns = []

# The name of the Pygments (syntax highlighting) style to use.
pygments_style = 'sphinx'

# If true, `todo` and `todoList` produce output, else they produce nothing.
todo_include_todos = True

# -- Options for HTML output ----------------------------------------------

# The theme to use for HTML and HTML Help pages.  See the documentation for
# a list of builtin themes.
#
html_theme = "ska_ser_sphinx_theme"

# Theme options are theme-specific and customize the look and feel of a theme
# further.  For a list of options available for each theme, see the
# documentation.
#
# html_theme_options = {}
html_context = {
    # 'favicon': 'img/favicon.ico',
    # 'logo': 'img/logo.jpg',
    # 'theme_logo_only': True,
    # 'display_github': True,  # Integrate GitHub
    # 'github_user': 'ska-telescope',  # Username
    # 'github_repo': 'ska-low-cbf-fw-pst',  # Repo name
    # 'github_version': 'master',  # Version
    # 'conf_py_path': '/src/',  # Path in the checkout to the docs root
}

# Add any paths that contain custom static files (such as style sheets) here,
# relative to this directory. They are copied after the builtin static files,
# so a file named "default.css" will overwrite the builtin "default.css".
html_static_path = []

# Custom sidebar templates, must be a dictionary that maps document names
# to template names.
#


# -- Options for HTMLHelp output ---------------------------------------------

# Output file base name for HTML help builder.
htmlhelp_basename = 'ska-low-cbf-corrfwdoc'

# -- Options for LaTeX output ---------------------------------------------

# -- Options for LaTeX output ------------------------------------------------

latex_elements = {
    # The paper size ('letterpaper' or 'a4paper').
    #
    # 'papersize': 'letterpaper',
    # The font size ('10pt', '11pt' or '12pt').
    #
    # 'pointsize': '10pt',
    # Additional stuff for the LaTeX preamble.
    #
    # 'preamble': '',
    # Latex figure (float) alignment
    #
    # 'figure_align': 'htbp',
}

# Grouping the document tree into LaTeX files. List of tuples
# (source start file, target name, title,
#  author, documentclass [howto, manual, or own class]).
latex_documents = [
    (
        master_doc,
        '{{project-name}}.tex',
        '{{project-name}} Documentation',
        '{{author}}',
        'manual'
    ),
]

# The name of an image file (relative to this directory) to place at the top of
# the title page.
#latex_logo = None

# -- Options for manual page output ------------------------------------------

# One entry per manual page. List of tuples
# (source start file, name, description, authors, manual section).
man_pages = [
    (master_doc, '{{project-name}}', '{{project-name}} Documentation',
     ['{{author}}'], 1)
]

# If true, show URL addresses after external links.
#man_show_urls = False


# -- Options for Texinfo output -------------------------------------------

# Grouping the document tree into Texinfo files. List of tuples
# (source start file, target name, title, author,
#  dir menu entry, description, category)
texinfo_documents = [
    (
        master_doc,
        '{{project-name}}',
        '{{project-name}} Documentation',
        '{{author}}', '{{project-name}}',
        'One line description of project.',
        'Miscellaneous'
    ),
]

# Documents to append as an appendix to all manuals.
#texinfo_appendices = []

# If false, no module index is generated.
#texinfo_domain_indices = True

# How to display URL addresses: 'footnote', 'no', or 'inline'.
#texinfo_show_urls = 'footnote'

# If true, do not generate a @detailmenu in the "Top" node's menu.
#texinfo_no_detailmenu = False
# -- Options for Epub output ----------------------------------------------

# Bibliographic Dublin Core info.
epub_title = project
epub_author = author
epub_publisher = author
epub_copyright = copyright

# The unique identifier of the text. This can be a ISBN number
# or the project homepage.
#
# epub_identifier = ''

# A unique identification for the text.
#
# epub_uid = ''

# A list of files that should not be packed into the epub file.
epub_exclude_files = ['search.html']
