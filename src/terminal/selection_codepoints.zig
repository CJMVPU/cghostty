// This file contains various default word boundaries used for
// selection logic. We put it in a separate file so that different
// subsystems can import it without introducing a number of
// dependencies.

/// Default word boundaries include common ASCII and Chinese punctuation.
pub const default_word_boundaries = [_]u21{
    0, // null
    ' ', // space
    '\t', // tab
    '\'', // single quote
    '"', // double quote
    '│', // U+2502 box drawing
    '`', // backtick
    '|', // pipe
    ':', // colon
    ';', // semicolon
    ',', // comma
    '(', // left paren
    ')', // right paren
    '[', // left bracket
    ']', // right bracket
    '{', // left brace
    '}', // right brace
    '<', // less than
    '>', // greater than
    '$', // dollar
    // Chinese punctuation, quotation marks, brackets, and fullwidth space.
    '，',
    '。',
    '；',
    '：',
    '！',
    '？',
    '、',
    '（',
    '）',
    '【',
    '】',
    '「',
    '」',
    '『',
    '』',
    '《',
    '》',
    '〈',
    '〉',
    '“',
    '”',
    '‘',
    '’',
    '　',
};

/// Default whitespace characters trimmed from line selections.
pub const default_line_whitespace = [_]u21{ 0, ' ', '\t' };
