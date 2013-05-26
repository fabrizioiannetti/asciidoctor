if RUBY_VERSION < '1.9'
  require 'rubygems'
end
require 'strscan'
require 'set'

$:.unshift(File.dirname(__FILE__))
#$:.unshift(File.join(File.dirname(__FILE__), '..', 'vendor'))

# Public: Methods for parsing Asciidoc input files and rendering documents
# using eRuby templates.
#
# Asciidoc documents comprise a header followed by zero or more sections.
# Sections are composed of blocks of content.  For example:
#
#   Doc Title
#   =========
#
#   SECTION 1
#   ---------
#
#   This is a paragraph block in the first section.
#
#   SECTION 2
#
#   This section has a paragraph block and an olist block.
#
#   1. Item 1
#   2. Item 2
#
# Examples:
#
# Use built-in templates:
#
#   lines = File.readlines("your_file.asc")
#   doc = Asciidoctor::Document.new(lines)
#   html = doc.render
#   File.open("your_file.html", "w+") do |file|
#     file.puts html
#   end
#
# Use custom (Tilt-supported) templates:
#
#   lines = File.readlines("your_file.asc")
#   doc = Asciidoctor::Document.new(lines, :template_dir => 'templates')
#   html = doc.render
#   File.open("your_file.html", "w+") do |file|
#     file.puts html
#   end
module Asciidoctor

  module SafeMode

    # A safe mode level that disables any of the security features enforced
    # by Asciidoctor (Ruby is still subject to its own restrictions).
    UNSAFE = 0;

    # A safe mode level that closely parallels safe mode in AsciiDoc. This value
    # prevents access to files which reside outside of the parent directory of
    # the source file and disables any macro other than the include::[] macro.
    SAFE = 1;

    # A safe mode level that disallows the document from setting attributes
    # that would affect the rendering of the document, in addition to all the
    # security features of SafeMode::SAFE. For instance, this level disallows
    # changing the backend or the source-highlighter using an attribute defined
    # in the source document. This is the most fundamental level of security
    # for server-side deployments (hence the name).
    SERVER = 10;

    # A safe mode level that disallows the document from attempting to read
    # files from the file system and including the contents of them into the
    # document, in additional to all the security features of SafeMode::SERVER.
    # For instance, this level disallows use of the include::[] macro and the
    # embedding of binary content (data uri), stylesheets and JavaScripts
    # referenced by the document.(Asciidoctor and trusted extensions may still
    # be allowed to embed trusted content into the document).
    #
    # Since Asciidoctor is aiming for wide adoption, this level is the default
    # and is recommended for server-side deployments.
    SECURE = 20;

    # A planned safe mode level that disallows the use of passthrough macros and
    # prevents the document from setting any known attributes, in addition to all
    # the security features of SafeMode::SECURE.
    #
    # Please note that this level is not currently implemented (and therefore not
    # enforced)!
    #PARANOID = 100;

  end

  # The root path of the Asciidoctor gem
  ROOT_PATH = File.expand_path(File.join(File.dirname(__FILE__), '..'))

  # Flag to indicate whether encoding of external strings needs to be forced to UTF-8
  # _All_ input data must be force encoded to UTF-8 if Encoding.default_external is *not* UTF-8
  # Address failures performing string operations that are reported as "invalid byte sequence in US-ASCII" 
  # Ruby 1.8 doesn't seem to experience this problem (perhaps because it isn't validating the encodings)
  FORCE_ENCODING = RUBY_VERSION > '1.9' && Encoding.default_external != Encoding::UTF_8

  # The default document type
  # Can influence markup generated by render templates
  DEFAULT_DOCTYPE = 'article'

  # The backend determines the format of the rendered output, default to html5
  DEFAULT_BACKEND = 'html5'

  DEFAULT_STYLESHEET_KEYS = ['', 'DEFAULT'].to_set

  DEFAULT_STYLESHEET_NAME = 'asciidoctor.css'

  # Pointers to the preferred version for a given backend.
  BACKEND_ALIASES = {
    'html' => 'html5',
    'docbook' => 'docbook45'
  }

  # Default page widths for calculating absolute widths
  DEFAULT_PAGE_WIDTHS = {
    'docbook' => 425
  }

  # Default extensions for the respective base backends
  DEFAULT_EXTENSIONS = {
    'html' => '.html',
    'docbook' => '.xml',
    'asciidoc' => '.ad',
    'markdown' => '.md'
  }

  SECTION_LEVELS = {
    '=' => 0,
    '-' => 1,
    '~' => 2,
    '^' => 3,
    '+' => 4
  }

  ADMONITION_STYLES = ['NOTE', 'TIP', 'IMPORTANT', 'WARNING', 'CAUTION'].to_set

  # NOTE: AsciiDoc doesn't support pass style for paragraph
  PARAGRAPH_STYLES = ['comment', 'example', 'literal', 'listing', 'normal', 'pass', 'quote', 'sidebar', 'source', 'verse', 'abstract', 'partintro'].to_set

  VERBATIM_STYLES = ['literal', 'listing', 'source', 'verse'].to_set

  DELIMITED_BLOCKS = {
    # NOTE: AsciiDoc doesn't support pass style for open block
    '--'   => [:open, ['comment', 'example', 'literal', 'listing', 'pass', 'quote', 'sidebar', 'source', 'verse', 'admonition', 'abstract', 'partintro'].to_set],
    '----' => [:listing, ['literal', 'source'].to_set],
    '....' => [:literal, ['listing', 'source'].to_set],
    '====' => [:example, ['admonition'].to_set],
    '****' => [:sidebar, Set.new],
    '____' => [:quote, ['verse'].to_set],
    '++++' => [:pass, Set.new],
    '|===' => [:table, Set.new],
    '!===' => [:table, Set.new],
    '////' => [:comment, Set.new],
    '```'  => [:fenced_code, Set.new],
    '~~~'  => [:fenced_code, Set.new]
  }

  BREAK_LINES = {
    %q{'''} => :ruler,
    '<<<'   => :page_break
  }

  LIST_CONTEXTS = [:ulist, :olist, :dlist, :colist]

  NESTABLE_LIST_CONTEXTS = [:ulist, :olist, :dlist]

  ORDERED_LIST_STYLES = [:arabic, :loweralpha, :lowerroman, :upperalpha, :upperroman]

  ORDERED_LIST_MARKER_PATTERNS = {
    :arabic => /\d+[.>]/,
    :loweralpha => /[a-z]\./,
    :upperalpha => /[A-Z]\./,
    :lowerroman => /[ivx]+\)/,
    :upperroman => /[IVX]+\)/
  }

  LIST_CONTINUATION = '+'

  LINE_BREAK = ' +'

  # NOTE allows for empty space in line as it could be left by the template engine
  BLANK_LINE_PATTERN = /^[[:blank:]]*\n/

  LINE_FEED_ENTITY = '&#10;' # or &#x0A;

  # Flags to control compliance with the behavior of AsciiDoc
  COMPLIANCE = {
    # AsciiDoc terminates paragraphs adjacent to
    # block content (delimiter or block attribute list)
    # Compliance value: true
    # TODO what about literal paragraph?
    :block_terminates_paragraph => true,

    # AsciiDoc does not treat paragraphs labeled with a
    # verbatim style (literal, listing, source, verse)
    # as verbatim; override this behavior
    # Compliance value: false
    :strict_verbatim_paragraphs => true,

    # AsciiDoc allows start and end delimiters around
    # a block to be different lengths
    # this option requires that they be the same
    # Compliance value: false
    :congruent_block_delimiters => true
  }

  # The following pattern, which appears frequently, captures the contents between square brackets,
  # ignoring escaped closing brackets (closing brackets prefixed with a backslash '\' character)
  #
  # Pattern:
  # (?:\[((?:\\\]|[^\]])*?)\])
  # Matches:
  # [enclosed text here] or [enclosed [text\] here]
  REGEXP = {
    # NOTE: this is a inline admonition note
    :admonition_inline => /^(#{ADMONITION_STYLES.to_a * '|'}):\s/,

    # [[Foo]]
    :anchor           => /^\[\[([^\s\[\]]+)\]\]$/,

    # Foowhatevs [[Bar]]
    :anchor_embedded  => /^(.*?)\s*\[\[([^\[\]]+)\]\]$/,

    # [[ref]] (anywhere inline)
    :anchor_macro     => /\\?\[\[([\w":].*?)\]\]/,

    # matches any block delimiter:
    #   open, listing, example, literal, comment, quote, sidebar, passthrough, table
    # NOTE position the most common blocks towards the front of the pattern
    :any_blk          => %r{^(?:--|(?:-|\.|=|\*|_|\+|/){4,}|[\|!]={3,}|(?:`|~){3,}.*)$},

    # detect a list item of any sort
    # [[:graph:]] is a non-blank character
    :any_list         => /^(?:
                             <?\d+>[[:blank:]]+[[:graph:]]|
                             [[:blank:]]*(?:(?:-|\*|\.){1,5}|\d+\.|[A-Za-z]\.|[IVXivx]+\))[[:blank:]]+[[:graph:]]|
                             [[:blank:]]*.*?(?::{2,4}|;;)(?:[[:blank:]]+[[:graph:]]|$)
                           )/x,

    # :foo: bar
    # :Author: Dan
    # :numbered!:
    :attr_entry       => /^:(\w.*?):(?:[[:blank:]]+(.*))?$/,

    # {name?value}
    :attr_conditional => /^\s*\{([^\?]+)\?\s*([^\}]+)\s*\}/,

    # +   Attribute values treat lines ending with ' +' as a continuation,
    #     not a line-break as elsewhere in the document, where this is
    #     a forced line break. This should be the same regexp as :line_break,
    #     below, but it gets its own entry because readability ftw, even
    #     though repeating regexps ftl.
    :attr_continue    => /^[[:blank:]]*(.*)[[:blank:]]\+[[:blank:]]*$/,

    # :foo!:
    :attr_delete      => /^:([^:]+)!:$/,

    # An attribute list above a block element
    #
    # Can be strictly positional:
    # [quote, Adam Smith, Wealth of Nations]
    # Or can have name/value pairs
    # [NOTE, caption="Good to know"]
    # Can be defined by an attribute
    # [{lead}]
    :blk_attr_list    => /^\[(|[[:blank:]]*[\w\{,.#"'].*)\]$/,

    # block attribute list or block id (bulk query)
    :attr_line        => /^\[(|[[:blank:]]*[\w\{,.#"'].*|\[[^\[\]]*\])\]$/,

    # attribute reference
    # {foo}
    # {counter:pcount:1}
    :attr_ref         => /(\\?)\{((?:set|counter2?):.+?|\w+(?:[\-]\w+)*)(\\?)\}/,

    # The author info line the appears immediately following the document title
    # John Doe <john@anonymous.com>
    :author_info      => /^(\w[\w\-'.]*)(?: +(\w[\w\-'.]*))?(?: +(\w[\w\-'.]*))?(?: +<([^>]+)>)?$/,

    # [[[Foo]]] (anywhere inline)
    :biblio_macro     => /\\?\[\[\[([\w:][\w:.-]*?)\]\]\]/,

    # callout reference inside literal text
    # <1>
    # special characters will already be replaced, hence their use in the regex
    :callout_render   => /\\?&lt;(\d+)&gt;/,
    # ...but not while scanning
    :callout_scan     => /\\?<(\d+)>/,

    # <1> Foo
    :colist           => /^<?(\d+)>[[:blank:]]+(.*)/,

    # ////
    # comment block
    # ////
    :comment_blk      => %r{^/{4,}$},

    # // (and then whatever)
    :comment          => %r{^//(?:[^/]|$)},

    # one,two;three;four
    :ssv_or_csv_delim   => /,|;/,

    # one two	three
    :space_delim      => /([^\\])[[:blank:]]+/,

    # one\ two\	three
    :escaped_space    => /\\([[:blank:]])/,

    # 29
    :digits           => /^\d+$/,

    # foo::  ||  foo::: || foo:::: || foo;;
    # Should be followed by a definition, on the same line...
    # foo:: That which precedes 'bar' (see also, <<bar>>)
    # ...or on a separate line
    # foo::
    #   That which precedes 'bar' (see also, <<bar>>)
    # The term may be an attribute reference
    # {term_foo}:: {def_foo}
    # REVIEW leading space has already been stripped, so may not need in regex
    :dlist            => /^[[:blank:]]*(.*?)(:{2,4}|;;)(?:[[:blank:]]+(.*))?$/,
    :dlist_siblings   => {
                           # (?:.*?[^:])? - a non-capturing group which grabs longest sequence of characters that doesn't end w/ colon
                           '::' => /^[[:blank:]]*((?:.*[^:])?)(::)(?:[[:blank:]]+(.*))?$/,
                           ':::' => /^[[:blank:]]*((?:.*[^:])?)(:::)(?:[[:blank:]]+(.*))?$/,
                           '::::' => /^[[:blank:]]*((?:.*[^:])?)(::::)(?:[[:blank:]]+(.*))?$/,
                           ';;' => /^[[:blank:]]*(.*)(;;)(?:[[:blank:]]+(.*))?$/
                         },
    # ====
    #:example          => /^={4,}$/,

    # footnote:[text]
    # footnoteref:[id,text]
    # footnoteref:[id]
    :footnote_macro   => /\\?(footnote|footnoteref):\[((?:\\\]|[^\]])*?)\]/,

    # image::filename.png[Caption]
    # video::http://youtube.com/12345[Cats vs Dogs]
    :media_blk_macro  => /^(image|video|audio)::(\S+?)\[((?:\\\]|[^\]])*?)\]$/,

    # image:filename.png[Alt Text]
    # image:filename.png[More [Alt\] Text] (alt text becomes "More [Alt] Text")
    :image_macro      => /\\?image:([^:\[]+)\[((?:\\\]|[^\]])*?)\]/,

    # indexterm:[Tigers,Big cats]
    # (((Tigers,Big cats)))
    :indexterm_macro  => /\\?(?:indexterm:(?:\[((?:\\\]|[^\]])*?)\])|\(\(\((.*?)\)\)\)(?!\)))/m,

    # indexterm2:[Tigers]
    # ((Tigers))
    :indexterm2_macro  => /\\?(?:indexterm2:(?:\[((?:\\\]|[^\]])*?)\])|\(\((.*?)\)\)(?!\)))/m,

    # whitespace at the beginning of the line
    :leading_blanks   => /^([[:blank:]]*)/,

    # leading parent directory references in path
    :leading_parent_dirs => /^(?:\.\.\/)*/,

    # +   From the Asciidoc User Guide: "A plus character preceded by at
    #     least one space character at the end of a non-blank line forces
    #     a line break. It generates a line break (br) tag for HTML outputs.
    #
    # +      (would not match because there's no space before +)
    #  +     (would match and capture '')
    # Foo +  (would and capture 'Foo')
    :line_break       => /^(.*)[[:blank:]]\+$/,

    # inline link and some inline link macro
    # FIXME revisit!
    :link_inline      => %r{(^|link:|\s|>|&lt;|[\(\)\[\]])(\\?(?:https?|ftp)://[^\s\[<]*[^\s.,\[<])(?:\[((?:\\\]|[^\]])*?)\])?},

    # inline link macro
    # link:path[label]
    :link_macro       => /\\?(?:link|mailto):([^\s\[]+)(?:\[((?:\\\]|[^\]])*?)\])/,

    # inline email address
    # doc.writer@asciidoc.org
    :email_inline     => /[\\>:]?\w[\w.%+-]*@[[:alnum:]][[:alnum:].-]*\.[[:alpha:]]{2,4}\b/, 

    # ----
    #:listing          => /^\-{4,}$/,

    # ....
    #:literal          => /^\.{4,}$/,

    # <TAB>Foo  or one-or-more-spaces-or-tabs then whatever
    :lit_par          => /^([[:blank:]]+.*)$/,

    # --
    #:open_blk         => /^\-\-$/,

    # . Foo (up to 5 consecutive dots)
    # 1. Foo (arabic, default)
    # a. Foo (loweralpha)
    # A. Foo (upperalpha)
    # i. Foo (lowerroman)
    # I. Foo (upperroman)
    # REVIEW leading space has already been stripped, so may not need in regex
    :olist            => /^[[:blank:]]*(\.{1,5}|\d+\.|[A-Za-z]\.|[IVXivx]+\))[[:blank:]]+(.*)$/,

    # ''' (ruler)
    # <<< (pagebreak)
    :break_line        => /^('|<){3,}$/,

    # ++++
    #:pass             => /^\+{4,}$/,

    # inline passthrough macros
    # +++text+++
    # $$text$$
    # pass:quotes[text]
    :pass_macro       => /\\?(?:(\+{3}|\${2})(.*?)\1|pass:([a-z,]*)\[((?:\\\]|[^\]])*?)\])/m,

    # passthrough macro allowed in value of attribute assignment
    # pass:[text]
    :pass_macro_basic => /^pass:([a-z,]*)\[(.*)\]$/,

    # inline literal passthrough macro
    # `text`
    :pass_lit         => /(^|[^`\w])(\\?`([^`\s]|[^`\s].*?\S)`)(?![`\w])/m,

    # placeholder for extracted passthrough text
    :pass_placeholder => /\x0(\d+)\x0/,

    # ____
    #:quote            => /^_{4,}$/,

    # The document revision info line the appears immediately following the
    # document title author info line, if present
    # v1.0, 2013-01-01: Ring in the new year release
    :revision_info    => /^(?:\D*(.*?),)?(?:\s*(?!:)(.*?))(?:\s*(?!^):\s*(.*))?$/,

    # '''
    #:ruler            => /^'{3,}$/,

    # ****
    #:sidebar_blk      => /^\*{4,}$/,

    # \' within a word
    :single_quote_esc => /(\w)\\'(\w)/,
    # an alternative if our backend generated single-quoted html/xml attributes
    #:single_quote_esc => /(\w|=)\\'(\w)/,

    # used for sanitizing attribute names
    :illegal_attr_name_chars => /[^\w\-]/,

    # |===
    # |table
    # |===
    #:table            => /^\|={3,}$/,

    # !===
    # !table
    # !===
    #:table_nested     => /^!={3,}$/,

    # 1*h,2*,^3e
    :table_colspec    => /^(?:(\d+)\*)?([<^>](?:\.[<^>]?)?|(?:[<^>]?\.)?[<^>])?(\d+)?([a-z])?$/,

    # 2.3+<.>m
    # TODO might want to use step-wise scan rather than this mega-regexp
    :table_cellspec => {
      :start => /^[[:blank:]]*(?:(\d+(?:\.\d*)?|(?:\d*\.)?\d+)([*+]))?([<^>](?:\.[<^>]?)?|(?:[<^>]?\.)?[<^>])?([a-z])?\|/,
      :end => /[[:blank:]]+(?:(\d+(?:\.\d*)?|(?:\d*\.)?\d+)([*+]))?([<^>](?:\.[<^>]?)?|(?:[<^>]?\.)?[<^>])?([a-z])?$/
    },

    # .Foo   but not  . Foo or ..Foo
    :blk_title        => /^\.([^\s.].*)$/,

    # matches double quoted text, capturing quote char and text (single-line)
    :dbl_quoted       => /^("|)(.*)\1$/,

    # matches double quoted text, capturing quote char and text (multi-line)
    :m_dbl_quoted     => /^("|)(.*)\1$/m,

    # == Foo
    # ^ yields a level 2 title
    #
    # == Foo ==
    # ^ also yields a level 2 title
    #
    # both equivalent to this two-line version:
    # Foo
    # ~~~
    #
    # match[1] is the delimiter, whose length determines the level
    # match[2] is the title itself
    # match[3] is an inline anchor, which becomes the section id
    :section_title     => /^(={1,6})\s+(\S.*?)(?:\s*\[\[([^\[]+)\]\])?(?:\s+\1)?$/,

    # does not begin with a dot and has at least one alphanumeric character
    :section_name      => /^((?=.*\w+.*)[^.].*?)$/,

    # ======  || ------ || ~~~~~~ || ^^^^^^ || ++++++
    # TODO build from SECTION_LEVELS keys
    :section_underline => /^(?:=|-|~|\^|\+)+$/,

    # toc::[]
    # toc::[levels=2]
    :toc              => /^toc::\[(.*?)\]$/,

    # * Foo (up to 5 consecutive asterisks)
    # - Foo
    # REVIEW leading space has already been stripped, so may not need in regex
    :ulist            => /^[[:blank:]]*(-|\*{1,5})[[:blank:]]+(.*)$/,

    # inline xref macro
    # <<id,reftext>> (special characters have already been escaped, hence the entity references)
    # xref:id[reftext]
    :xref_macro       => /\\?(?:&lt;&lt;([\w":].*?)&gt;&gt;|xref:([\w":].*?)\[(.*?)\])/m,

    # ifdef::basebackend-html[]
    # ifndef::theme[]
    # ifeval::["{asciidoctor-version}" >= "0.1.0"]
    # ifdef::asciidoctor[Asciidoctor!]
    # endif::theme[]
    # endif::basebackend-html[]
    # endif::[]
    :ifdef_macro      => /^[\\]?(ifdef|ifndef|ifeval|endif)::(\S*?(?:([,\+])\S+?)?)\[(.+)?\]$/,

    # "{asciidoctor-version}" >= "0.1.0"
    :eval_expr        => /^(\S.*?)[[:blank:]]*(==|!=|<=|>=|<|>)[[:blank:]]*(\S.*)$/,
    # ...or if we want to be more strict up front about what's on each side
    #:eval_expr        => /^(true|false|("|'|)\{\w+(?:\-\w+)*\}\2|("|')[^\3]*\3|\-?\d+(?:\.\d+)*)[[:blank:]]*(==|!=|<=|>=|<|>)[[:blank:]]*(true|false|("|'|)\{\w+(?:\-\w+)*\}\6|("|')[^\7]*\7|\-?\d+(?:\.\d+)*)$/,

    # include::chapter1.ad[]
    # include::example.txt[lines=1;2;5..10]
    :include_macro    => /^\\?include::([^\[]+)\[(.*?)\]$/,

    # http://domain
    # https://domain
    # data:info
    :uri_sniff        => /^[[:alpha:]][[:alnum:].+-]*:/i,

    :uri_encode_chars => /[^\w\-.!~*';:@=+$,()\[\]]/
  }

  INTRINSICS = Hash.new{|h,k| STDERR.puts "Missing intrinsic: #{k.inspect}"; "{#{k}}"}.merge(
    {
    'startsb'    => '[',
    'endsb'      => ']',
    'brvbar'     => '|',
    'caret'      => '^',
    'asterisk'   => '*',
    'tilde'      => '~',
    'plus'       => '&#43;',
    'apostrophe' => '\'',
    'backslash'  => '\\',
    'backtick'   => '`',
    'empty'      => '',
    'sp'         => ' ',
    'space'      => ' ',
    'two-colons' => '::',
    'two-semicolons' => ';;',
    'nbsp'       => '&#160;',
    'deg'        => '&#176;',
    'zwsp'       => '&#8203;',
    'quot'       => '&#34;',
    'apos'       => '&#39;',
    'lsquo'      => '&#8216;',
    'rsquo'      => '&#8217;',
    'ldquo'      => '&#8220;',
    'rdquo'      => '&#8221;',
    'wj'         => '&#8288;',
    'amp'        => '&',
    'lt'         => '<',
    'gt'         => '>'
    }
  )

  SPECIAL_CHARS = {
    '<' => '&lt;',
    '>' => '&gt;',
    '&' => '&amp;'
  }

  SPECIAL_CHARS_PATTERN = /[#{SPECIAL_CHARS.keys.join}]/
  #SPECIAL_CHARS_PATTERN = /(?:<|>|&(?![[:alpha:]]{2,};|#[[:digit:]]{2,}+;|#x[[:alnum:]]{2,}+;))/

  # unconstrained quotes:: can appear anywhere
  # constrained quotes:: must be bordered by non-word characters
  # NOTE these substituions are processed in the order they appear here and
  # the order in which they are replaced is important
  QUOTE_SUBS = [

    # **strong**
    [:strong, :unconstrained, /\\?(?:\[([^\]]+?)\])?\*\*(.+?)\*\*/m],

    # *strong*
    [:strong, :constrained, /(^|[^\w;:}])(?:\[([^\]]+?)\])?\*(\S|\S.*?\S)\*(?=\W|$)/m],

    # ``double-quoted''
    [:double, :constrained, /(^|[^\w;:}])(?:\[([^\]]+?)\])?``(\S|\S.*?\S)''(?=\W|$)/m],

    # 'emphasis'
    [:emphasis, :constrained, /(^|[^\w;:}])(?:\[([^\]]+?)\])?'(\S|\S.*?\S)'(?=\W|$)/m],

    # `single-quoted'
    [:single, :constrained, /(^|[^\w;:}])(?:\[([^\]]+?)\])?`(\S|\S.*?\S)'(?=\W|$)/m],

    # ++monospaced++
    [:monospaced, :unconstrained, /\\?(?:\[([^\]]+?)\])?\+\+(.+?)\+\+/m],

    # +monospaced+
    [:monospaced, :constrained, /(^|[^\w;:}])(?:\[([^\]]+?)\])?\+(\S|\S.*?\S)\+(?=\W|$)/m],

    # __emphasis__
    [:emphasis, :unconstrained, /\\?(?:\[([^\]]+?)\])?\_\_(.+?)\_\_/m],

    # _emphasis_
    [:emphasis, :constrained, /(^|[^\w;:}])(?:\[([^\]]+?)\])?_(\S|\S.*?\S)_(?=\W|$)/m],

    # ##unquoted##
    [:none, :unconstrained, /\\?(?:\[([^\]]+?)\])?##(.+?)##/m],

    # #unquoted#
    [:none, :constrained, /(^|[^\w;:}])(?:\[([^\]]+?)\])?#(\S|\S.*?\S)#(?=\W|$)/m],

    # ^superscript^
    [:superscript, :unconstrained, /\\?(?:\[([^\]]+?)\])?\^(.+?)\^/m],

    # ~subscript~
    [:subscript, :unconstrained, /\\?(?:\[([^\]]+?)\])?\~(.+?)\~/m]
  ]

  # NOTE in Ruby 1.8.7, [^\\] does not match start of line,
  # so we need to match it explicitly
  # order is significant
  REPLACEMENTS = [
    # (C)
    [/\\?\(C\)/, '&#169;', :none],
    # (R)
    [/\\?\(R\)/, '&#174;', :none],
    # (TM)
    [/\\?\(TM\)/, '&#8482;', :none],
    # foo -- bar
    [/(^|\n| |\\)--( |\n|$)/, '&#8201;&#8212;&#8201;', :none],
    # foo--bar
    [/(\w)\\?--(?=\w)/, '&#8212;', :leading],
    # ellipsis
    [/\\?\.\.\./, '&#8230;', :leading],
    # single quotes
    [/(\w)\\?'(\w)/, '&#8217;', :bounding],
    # right arrow ->
    [/\\?-&gt;/, '&#8594;', :none],
    # right double arrow =>
    [/\\?=&gt;/, '&#8658;', :none],
    # left arrow <-
    [/\\?&lt;-/, '&#8592;', :none],
    # right left arrow <=
    [/\\?&lt;=/, '&#8656;', :none],
    # restore entities
    [/\\?(&)amp;((?:[[:alpha:]]+|#[[:digit:]]+|#x[[:alnum:]]+);)/, '', :bounding]
  ]

  # Public: Parse the AsciiDoc source input into an Asciidoctor::Document
  #
  # Accepts input as an IO (or StringIO), String or String Array object. If the
  # input is a File, information about the file is stored in attributes on the
  # Document object.
  #
  # input   - the AsciiDoc source as a IO, String or Array.
  # options - a String, Array or Hash of options to control processing (default: {})
  #           String and Array values are converted into a Hash.
  #           See Asciidoctor::Document#initialize for details about options.
  # block   - a callback block for handling include::[] directives
  #
  # returns the Asciidoctor::Document
  def self.load(input, options = {}, &block)
    if (monitor = options.fetch(:monitor, false))
      start = Time.now
    end

    attrs = (options[:attributes] ||= {})
    if attrs.is_a? Hash
      # all good; placed here as optimization
    elsif attrs.is_a? Array
      attrs = options[:attributes] = attrs.inject({}) do |accum, entry|
        k, v = entry.split '=', 2
        accum[k] = v || ''
        accum
      end
    elsif attrs.is_a? String
      # convert non-escaped spaces into null character, so we split on the
      # correct spaces chars, and restore escaped spaces
      attrs = attrs.gsub(REGEXP[:space_delim], "\\1\0").gsub(REGEXP[:escaped_space], '\1')

      attrs = options[:attributes] = attrs.split("\0").inject({}) do |accum, entry|
        k, v = entry.split '=', 2
        accum[k] = v || ''
        accum
      end
    else
      raise ArgumentError, 'illegal type for attributes option'
    end

    lines = nil
    if input.is_a? File
      lines = input.readlines
      input_mtime = input.mtime
      input_path = File.expand_path(input.path)
      # hold off on setting infile and indir until we get a better sense of their purpose
      attrs['docfile'] = input_path
      attrs['docdir'] = File.dirname(input_path)
      attrs['docname'] = File.basename(input_path, File.extname(input_path))
      attrs['docdate'] = input_mtime.strftime('%Y-%m-%d')
      attrs['doctime'] = input_mtime.strftime('%H:%M:%S %Z')
      attrs['docdatetime'] = [attrs['docdate'], attrs['doctime']] * ' '
    elsif input.respond_to?(:readlines)
      input.rewind rescue nil
      lines = input.readlines
    elsif input.is_a?(String)
      lines = input.lines.entries
    elsif input.is_a?(Array)
      lines = input.dup
    else
      raise "Unsupported input type: #{input.class}"
    end

    if monitor
      read_time = Time.now - start
      start = Time.now
    end

    doc = Document.new(lines, options, &block) 
    if monitor
      parse_time = Time.now - start
      monitor[:read] = read_time
      monitor[:parse] = parse_time
      monitor[:load] = read_time + parse_time
    end
    doc
  end

  # Public: Parse the contents of the AsciiDoc source file into an Asciidoctor::Document
  #
  # Accepts input as an IO, String or String Array object. If the
  # input is a File, information about the file is stored in
  # attributes on the Document.
  #
  # input   - the String AsciiDoc source filename
  # options - a String, Array or Hash of options to control processing (default: {})
  #           String and Array values are converted into a Hash.
  #           See Asciidoctor::Document#initialize for details about options.
  # block   - a callback block for handling include::[] directives
  #
  # returns the Asciidoctor::Document
  def self.load_file(filename, options = {}, &block)
    Asciidoctor.load(File.new(filename), options, &block)
  end

  # Public: Parse the AsciiDoc source input into an Asciidoctor::Document and render it
  # to the specified backend format
  #
  # Accepts input as an IO, String or String Array object. If the
  # input is a File, information about the file is stored in
  # attributes on the Document.
  #
  # If the :in_place option is true, and the input is a File, the output is
  # written to a file adjacent to the input file, having an extension that
  # corresponds to the backend format. Otherwise, if the :to_file option is
  # specified, the file is written to that file. If :to_file is not an absolute
  # path, it is resolved relative to :to_dir, if given, otherwise the
  # Document#base_dir. If the target directory does not exist, it will not be
  # created unless the :mkdirs option is set to true. If the file cannot be
  # written because the target directory does not exist, or because it falls
  # outside of the Document#base_dir in safe mode, an IOError is raised.
  #
  # If the output is going to be written to a file, the header and footer are
  # rendered unless specified otherwise (writing to a file implies creating a
  # standalone document). Otherwise, the header and footer are not rendered by
  # default and the rendered output is returned.
  #
  # input   - the String AsciiDoc source filename
  # options - a String, Array or Hash of options to control processing (default: {})
  #           String and Array values are converted into a Hash.
  #           See Asciidoctor::Document#initialize for details about options.
  # block   - a callback block for handling include::[] directives
  #
  # returns the Document object if the rendered result String is written to a
  # file, otherwise the rendered result String
  def self.render(input, options = {}, &block)
    in_place = options.delete(:in_place) || false
    to_file = options.delete(:to_file)
    to_dir = options.delete(:to_dir)
    mkdirs = options.delete(:mkdirs) || false
    monitor = options.fetch(:monitor, false)

    write_in_place = in_place && input.is_a?(File)
    write_to_target = to_file || to_dir
    stream_output = !to_file.nil? && to_file.respond_to?(:write)

    if write_in_place && write_to_target
      raise ArgumentError, 'the option :in_place cannot be used with either the :to_dir or :to_file option'
    end

    if !options.has_key?(:header_footer) && (write_in_place || write_to_target)
      options[:header_footer] = true
    end

    doc = Asciidoctor.load(input, options, &block)

    if to_file == '/dev/null'
      return doc
    elsif write_in_place
      to_file = File.join(File.dirname(input.path), "#{doc.attributes['docname']}#{doc.attributes['outfilesuffix']}")
    elsif !stream_output && write_to_target
      working_dir = options.has_key?(:base_dir) ? File.expand_path(options[:base_dir]) : File.expand_path(Dir.pwd)
      # QUESTION should the jail be the working_dir or doc.base_dir???
      jail = doc.safe >= SafeMode::SAFE ? working_dir : nil
      if to_dir
        to_dir = doc.normalize_system_path(to_dir, working_dir, jail, :target_name => 'to_dir', :recover => false)
        if to_file
          to_file = doc.normalize_system_path(to_file, to_dir, nil, :target_name => 'to_dir', :recover => false)
          # reestablish to_dir as the final target directory (in the case to_file had directory segments)
          to_dir = File.dirname(to_file)
        else
          to_file = File.join(to_dir, "#{doc.attributes['docname']}#{doc.attributes['outfilesuffix']}")
        end
      elsif to_file
        to_file = doc.normalize_system_path(to_file, working_dir, jail, :target_name => 'to_dir', :recover => false)
        # establish to_dir as the final target directory (in the case to_file had directory segments)
        to_dir = File.dirname(to_file)
      end

      if !File.directory? to_dir
        if mkdirs
          Helpers.require_library 'fileutils'
          FileUtils.mkdir_p to_dir
        else
          raise IOError, "target directory does not exist: #{to_dir}"
        end
      end
    end

    start = Time.now if monitor
    output = doc.render

    if monitor
      render_time = Time.now - start
      monitor[:render] = render_time
      monitor[:load_render] = monitor[:load] + render_time
    end

    if to_file
      start = Time.now if monitor
      if stream_output
        to_file.write output.rstrip
        # ensure there's a trailing endline
        to_file.write "\n"
      else
        File.open(to_file, 'w') {|file| file.write output }
        # these assignments primarily for testing, diagnostics or reporting
        doc.attributes['outfile'] = outfile = File.expand_path(to_file)
        doc.attributes['outdir'] = File.dirname(outfile)
      end
      if monitor
        write_time = Time.now - start
        monitor[:write] = write_time
        monitor[:total] = monitor[:load_render] + write_time
      end

      # NOTE document cannot control this behavior if safe >= SafeMode::SERVER
      if !stream_output && doc.attr?('copycss') &&
          doc.attr?('linkcss') && DEFAULT_STYLESHEET_KEYS.include?(doc.attr('stylesheet'))
        Helpers.require_library 'fileutils'
        outdir = doc.attr('outdir')
        stylesdir = doc.normalize_system_path(doc.attr('stylesdir'), outdir,
            doc.safe >= SafeMode::SAFE ? outdir : nil)
        Helpers.mkdir_p stylesdir
        File.open(File.join(stylesdir, DEFAULT_STYLESHEET_NAME), 'w') {|f|
          f.write Asciidoctor::HTML5.default_asciidoctor_stylesheet
        }
      end
      doc
    else
      output
    end
  end

  # Public: Parse the contents of the AsciiDoc source file into an Asciidoctor::Document
  # and render it to the specified backend format
  #
  # input   - the String AsciiDoc source filename
  # options - a String, Array or Hash of options to control processing (default: {})
  #           String and Array values are converted into a Hash.
  #           See Asciidoctor::Document#initialize for details about options.
  # block   - a callback block for handling include::[] directives
  #
  # returns the Document object if the rendered result String is written to a
  # file, otherwise the rendered result String
  def self.render_file(filename, options = {}, &block)
    Asciidoctor.render(File.new(filename), options, &block)
  end

  # NOTE still contemplating this method
  #def self.parse_document_header(input, options = {})
  #  document = Document.new [], options
  #  reader = Reader.new input, document, true
  #  Lexer.parse_document_header reader, document
  #  document
  #end

  # modules
  require 'asciidoctor/debug'
  require 'asciidoctor/substituters'
  require 'asciidoctor/helpers'

  # abstract classes
  require 'asciidoctor/abstract_node'
  require 'asciidoctor/abstract_block'

  # concrete classes
  require 'asciidoctor/attribute_list'
  require 'asciidoctor/backends/base_template'
  require 'asciidoctor/block'
  require 'asciidoctor/callouts'
  require 'asciidoctor/document'
  require 'asciidoctor/inline'
  require 'asciidoctor/lexer'
  require 'asciidoctor/list_item'
  require 'asciidoctor/path_resolver'
  require 'asciidoctor/reader'
  require 'asciidoctor/renderer'
  require 'asciidoctor/section'
  require 'asciidoctor/table'

  # info
  require 'asciidoctor/version'
end
