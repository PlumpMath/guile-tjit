/* Copyright (C) 1995,1996,1997,1999,2000,2001,2003 Free Software
 * Foundation, Inc.
 * 
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
 */




#include <stdio.h>
#include "libguile/_scm.h"
#include "libguile/chars.h"
#include "libguile/eval.h"
#include "libguile/unif.h"
#include "libguile/keywords.h"
#include "libguile/alist.h"
#include "libguile/srcprop.h"
#include "libguile/hashtab.h"
#include "libguile/hash.h"
#include "libguile/ports.h"
#include "libguile/root.h"
#include "libguile/strings.h"
#include "libguile/strports.h"
#include "libguile/vectors.h"
#include "libguile/validate.h"

#include "libguile/read.h"



SCM_GLOBAL_SYMBOL (scm_sym_dot, ".");
SCM_SYMBOL (scm_keyword_prefix, "prefix");

scm_t_option scm_read_opts[] = {
  { SCM_OPTION_BOOLEAN, "copy", 0,
    "Copy source code expressions." },
  { SCM_OPTION_BOOLEAN, "positions", 0,
    "Record positions of source code expressions." },
  { SCM_OPTION_BOOLEAN, "case-insensitive", 0,
    "Convert symbols to lower case."},
  { SCM_OPTION_SCM, "keywords", SCM_UNPACK (SCM_BOOL_F),
    "Style of keyword recognition: #f or 'prefix."}
#if SCM_ENABLE_ELISP
  ,
  { SCM_OPTION_BOOLEAN, "elisp-vectors", 0,
    "Support Elisp vector syntax, namely `[...]'."},
  { SCM_OPTION_BOOLEAN, "elisp-strings", 0,
    "Support `\\(' and `\\)' in strings."}
#endif
};

/*
  Give meaningful error messages for errors

  We use the format

  FILE:LINE:COL: MESSAGE
  This happened in ....

  This is not standard GNU format, but the test-suite likes the real
  message to be in front.

 */


static void
scm_input_error(char const * function,
		SCM port, const char * message, SCM arg)
{
  char *fn = SCM_STRINGP (SCM_FILENAME(port))
    ? SCM_STRING_CHARS(SCM_FILENAME(port))
    : "#<unknown port>";

  SCM string_port =  scm_open_output_string ();
  SCM string = SCM_EOL;
  scm_simple_format (string_port,
		     scm_makfrom0str ("~A:~S:~S: ~A"),
		     scm_list_4 (scm_makfrom0str (fn),
				 scm_int2num (SCM_LINUM (port) + 1),
				 scm_int2num (SCM_COL (port) + 1),
				 scm_makfrom0str (message)));

    
  string = scm_get_output_string (string_port);
  scm_close_output_port (string_port);
  scm_error_scm (scm_str2symbol ("read-error"),
		 scm_makfrom0str (function),
		 string,
		 arg,
		 SCM_BOOL_F);
}


SCM_DEFINE (scm_read_options, "read-options-interface", 0, 1, 0, 
            (SCM setting),
	    "Option interface for the read options. Instead of using\n"
	    "this procedure directly, use the procedures @code{read-enable},\n"
	    "@code{read-disable}, @code{read-set!} and @code{read-options}.")
#define FUNC_NAME s_scm_read_options
{
  SCM ans = scm_options (setting,
			 scm_read_opts,
			 SCM_N_READ_OPTIONS,
			 FUNC_NAME);
  if (SCM_COPY_SOURCE_P)
    SCM_RECORD_POSITIONS_P = 1;
  return ans;
}
#undef FUNC_NAME

/* An association list mapping extra hash characters to procedures.  */
static SCM *scm_read_hash_procedures;

SCM_DEFINE (scm_read, "read", 0, 1, 0, 
            (SCM port),
	    "Read an s-expression from the input port @var{port}, or from\n"
	    "the current input port if @var{port} is not specified.\n"
	    "Any whitespace before the next token is discarded.")
#define FUNC_NAME s_scm_read
{
  int c;
  SCM tok_buf, copy;

  if (SCM_UNBNDP (port))
    port = scm_cur_inp;
  SCM_VALIDATE_OPINPORT (1, port);

  c = scm_flush_ws (port, (char *) NULL);
  if (EOF == c)
    return SCM_EOF_VAL;
  scm_ungetc (c, port);

  tok_buf = scm_allocate_string (30);
  return scm_lreadr (&tok_buf, port, &copy);
}
#undef FUNC_NAME



char *
scm_grow_tok_buf (SCM *tok_buf)
{
  size_t oldlen = SCM_STRING_LENGTH (*tok_buf);
  SCM newstr = scm_allocate_string (2 * oldlen);
  size_t i;

  for (i = 0; i != oldlen; ++i)
    SCM_STRING_CHARS (newstr) [i] = SCM_STRING_CHARS (*tok_buf) [i];

  *tok_buf = newstr;
  return SCM_STRING_CHARS (newstr);
}



int 
scm_flush_ws (SCM port, const char *eoferr)
{
  register int c;
  while (1)
    switch (c = scm_getc (port))
      {
      case EOF:
      goteof:
	if (eoferr)
	  {
	    scm_input_error (eoferr,
			     port,
			     "end of file",
			     SCM_EOL);
	  }
	return c;
      case ';':
      lp:
	switch (c = scm_getc (port))
	  {
	  case EOF:
	    goto goteof;
	  default:
	    goto lp;
	  case SCM_LINE_INCREMENTORS:
	    break;
	  }
	break;
      case SCM_LINE_INCREMENTORS:
      case SCM_SINGLE_SPACES:
      case '\t':
	break;
      default:
	return c;
      }
}



int
scm_casei_streq (char *s1, char *s2)
{
  while (*s1 && *s2)
    if (scm_downcase((int)*s1) != scm_downcase((int)*s2))
      return 0;
    else
      {
	++s1;
	++s2;
      }
  return !(*s1 || *s2);
}


/* recsexpr is used when recording expressions
 * constructed by read:sharp.
 */
static SCM
recsexpr (SCM obj, long line, int column, SCM filename)
{
  if (!SCM_CONSP(obj)) {
    return obj;
  } else {
    SCM tmp = obj, copy;
    /* If this sexpr is visible in the read:sharp source, we want to
       keep that information, so only record non-constant cons cells
       which haven't previously been read by the reader. */
    if (SCM_FALSEP (scm_whash_lookup (scm_source_whash, obj)))
      {
	if (SCM_COPY_SOURCE_P)
	  {
	    copy = scm_cons (recsexpr (SCM_CAR (obj), line, column, filename),
			     SCM_UNDEFINED);
	    while ((tmp = SCM_CDR (tmp)) && SCM_CONSP (tmp))
	      {
		SCM_SETCDR (copy, scm_cons (recsexpr (SCM_CAR (tmp),
						      line,
						      column,
						      filename),
					    SCM_UNDEFINED));
		copy = SCM_CDR (copy);
	      }
	    SCM_SETCDR (copy, tmp);
	  }
	else
	  {
	    recsexpr (SCM_CAR (obj), line, column, filename);
	    while ((tmp = SCM_CDR (tmp)) && SCM_CONSP (tmp))
	      recsexpr (SCM_CAR (tmp), line, column, filename);
	    copy = SCM_UNDEFINED;
	  }
	scm_whash_insert (scm_source_whash,
			  obj,
			  scm_make_srcprops (line,
					     column,
					     filename,
					     copy,
					     SCM_EOL));
      }
    return obj;
  }
}

/* Consume an SCSH-style block comment.  Assume that we've already
   read the initial `#!', and eat characters until we get a
   newline/exclamation-point/sharp-sign/newline sequence.  */

static void
skip_scsh_block_comment (SCM port)
#define FUNC_NAME "skip_scsh_block_comment"
{
  /* Is this portable?  Dear God, spare me from the non-eight-bit
     characters.  But is it tasteful?  */
  long history = 0;

  for (;;)
    {
      int c = scm_getc (port);

      if (c == EOF)
	SCM_MISC_ERROR ("unterminated `#! ... !#' comment", SCM_EOL);
      history = ((history << 8) | (c & 0xff)) & 0xffffffff;

      /* Were the last four characters read "\n!#\n"?  */
      if (history == (('\n' << 24) | ('!' << 16) | ('#' << 8) | '\n'))
	return;
    }
}
#undef FUNC_NAME


static SCM scm_get_hash_procedure(int c);
static SCM scm_i_lreadparen (SCM *, SCM, char *, SCM *, char);

static char s_list[]="list";
static char s_vector[]="vector";

SCM 
scm_lreadr (SCM *tok_buf, SCM port, SCM *copy)
#define FUNC_NAME "scm_lreadr"
{
  int c;
  size_t j;
  SCM p;
				  
 tryagain:
  c = scm_flush_ws (port, s_scm_read);
 tryagain_no_flush_ws:
  switch (c)
    {
    case EOF:
      return SCM_EOF_VAL;

    case '(':
      return SCM_RECORD_POSITIONS_P
	? scm_lreadrecparen (tok_buf, port, s_list, copy)
	: scm_i_lreadparen (tok_buf, port, s_list, copy, ')');
    case ')':
      scm_input_error (FUNC_NAME, port,"unexpected \")\"", SCM_EOL);
      goto tryagain;
    
#if SCM_ENABLE_ELISP
    case '[':
      if (SCM_ELISP_VECTORS_P)
	{
	  p = scm_i_lreadparen (tok_buf, port, s_vector, copy, ']');
	  return SCM_NULLP (p) ? scm_nullvect : scm_vector (p);
	}
      goto read_token;
#endif
    case '\'':
      p = scm_sym_quote;
      goto recquote;
    case '`':
      p = scm_sym_quasiquote;
      goto recquote;
    case ',':
      c = scm_getc (port);
      if ('@' == c)
	p = scm_sym_uq_splicing;
      else
	{
	  scm_ungetc (c, port);
	  p = scm_sym_unquote;
	}
    recquote:
      p = scm_cons2 (p,
		     scm_lreadr (tok_buf, port, copy),
		     SCM_EOL);
      if (SCM_RECORD_POSITIONS_P)
	scm_whash_insert (scm_source_whash,
			  p,
			  scm_make_srcprops (SCM_LINUM (port),
					     SCM_COL (port) - 1,
					     SCM_FILENAME (port),
					     SCM_COPY_SOURCE_P
					     ? (*copy = scm_cons2 (SCM_CAR (p),
								   SCM_CAR (SCM_CDR (p)),
								   SCM_EOL))
					     : SCM_UNDEFINED,
					     SCM_EOL));
      return p;
    case '#':
      c = scm_getc (port);

      {
	/* Check for user-defined hash procedure first, to allow
	   overriding of builtin hash read syntaxes.  */
	SCM sharp = scm_get_hash_procedure (c);
	if (!SCM_FALSEP (sharp))
	  {
	    int line = SCM_LINUM (port);
	    int column = SCM_COL (port) - 2;
	    SCM got;

	    got = scm_call_2 (sharp, SCM_MAKE_CHAR (c), port);
	    if (SCM_EQ_P (got, SCM_UNSPECIFIED))
	      goto handle_sharp;
	    if (SCM_RECORD_POSITIONS_P)
	      return *copy = recsexpr (got, line, column,
				       SCM_FILENAME (port));
	    else
	      return got;
	  }
      }
    handle_sharp:
      switch (c)
	{
	case '(':
	  p = scm_i_lreadparen (tok_buf, port, s_vector, copy, ')');
	  return SCM_NULLP (p) ? scm_nullvect : scm_vector (p);

	case 't':
	case 'T':
	  return SCM_BOOL_T;
	case 'f':
	case 'F':
	  return SCM_BOOL_F;

	case 'b':
	case 'B':
	case 'o':
	case 'O':
	case 'd':
	case 'D':
	case 'x':
	case 'X':
	case 'i':
	case 'I':
	case 'e':
	case 'E':
	  scm_ungetc (c, port);
	  c = '#';
	  goto num;

	case '!':
	  /* start of a shell script.  Parse as a block comment,
	     terminated by !#, just like SCSH.  */
	  skip_scsh_block_comment (port);
	  /* EOF is not an error here */
	  c = scm_flush_ws (port, (char *)NULL);
	  goto tryagain_no_flush_ws;

#if SCM_HAVE_ARRAYS
	case '*':
	  j = scm_read_token (c, tok_buf, port, 0);
	  p = scm_istr2bve (SCM_STRING_CHARS (*tok_buf) + 1, (long) (j - 1));
	  if (!SCM_FALSEP (p))
	    return p;
	  else
	    goto unkshrp;
#endif

	case '{':
	  j = scm_read_token (c, tok_buf, port, 1);
	  return scm_mem2symbol (SCM_STRING_CHARS (*tok_buf), j);

	case '\\':
	  c = scm_getc (port);
	  j = scm_read_token (c, tok_buf, port, 0);
	  if (j == 1)
	    return SCM_MAKE_CHAR (c);
	  if (c >= '0' && c < '8')
	    {
	      /* Dirk:FIXME::  This type of character syntax is not R5RS
	       * compliant.  Further, it should be verified that the constant
	       * does only consist of octal digits.  Finally, it should be
	       * checked whether the resulting fixnum is in the range of
	       * characters.  */
	      p = scm_i_mem2number (SCM_STRING_CHARS (*tok_buf), j, 8);
	      if (SCM_INUMP (p))
		return SCM_MAKE_CHAR (SCM_INUM (p));
	    }
	  for (c = 0; c < scm_n_charnames; c++)
	    if (scm_charnames[c]
		&& (scm_casei_streq (scm_charnames[c], SCM_STRING_CHARS (*tok_buf))))
	      return SCM_MAKE_CHAR (scm_charnums[c]);
	  scm_input_error (FUNC_NAME, port, "unknown # object", SCM_EOL);

	  /* #:SYMBOL is a syntax for keywords supported in all contexts.  */
	case ':':
	  j = scm_read_token ('-', tok_buf, port, 0);
	  p = scm_mem2symbol (SCM_STRING_CHARS (*tok_buf), j);
	  return scm_make_keyword_from_dash_symbol (p);

	default:
	callshrp:
	  {
	    SCM sharp = scm_get_hash_procedure (c);

	    if (!SCM_FALSEP (sharp))
	      {
		int line = SCM_LINUM (port);
		int column = SCM_COL (port) - 2;
		SCM got;

		got = scm_call_2 (sharp, SCM_MAKE_CHAR (c), port);
		if (SCM_EQ_P (got, SCM_UNSPECIFIED))
		  goto unkshrp;
		if (SCM_RECORD_POSITIONS_P)
		  return *copy = recsexpr (got, line, column,
					   SCM_FILENAME (port));
		else
		  return got;
	      }
	  }
	unkshrp:
	scm_input_error (FUNC_NAME, port, "Unknown # object: ~S",
		     scm_list_1 (SCM_MAKE_CHAR (c)));
	}

    case '"':
      j = 0;
      while ('"' != (c = scm_getc (port)))
	{
	  if (c == EOF)
	    str_eof: scm_input_error (FUNC_NAME, port, "end of file in string constant", SCM_EOL);

	  while (j + 2 >= SCM_STRING_LENGTH (*tok_buf))
	    scm_grow_tok_buf (tok_buf);

	  if (c == '\\')
	    switch (c = scm_getc (port))
	      {
	      case EOF:
		goto str_eof;
	      case '"':
	      case '\\':
		break;
#if SCM_ENABLE_ELISP
	      case '(':
	      case ')':
		if (SCM_ESCAPED_PARENS_P)
		  break;
		goto bad_escaped;
#endif
	      case '\n':
		continue;
	      case '0':
		c = '\0';
		break;
	      case 'f':
		c = '\f';
		break;
	      case 'n':
		c = '\n';
		break;
	      case 'r':
		c = '\r';
		break;
	      case 't':
		c = '\t';
		break;
	      case 'a':
		c = '\007';
		break;
	      case 'v':
		c = '\v';
		break;
	      case 'x':
		{
		  int a, b;
		  a = scm_getc (port);
		  if (a == EOF) goto str_eof;
		  b = scm_getc (port);
		  if (b == EOF) goto str_eof;
		  if      ('0' <= a && a <= '9') a -= '0';
		  else if ('A' <= a && a <= 'F') a = a - 'A' + 10;
		  else if ('a' <= a && a <= 'f') a = a - 'a' + 10;
		  else goto bad_escaped;
		  if      ('0' <= b && b <= '9') b -= '0';
		  else if ('A' <= b && b <= 'F') b = b - 'A' + 10;
		  else if ('a' <= b && b <= 'f') b = b - 'a' + 10;
		  else goto bad_escaped;
		  c = a * 16 + b;
		  break;
		}
	      default:
	      bad_escaped:
		scm_input_error(FUNC_NAME, port,
				"illegal character in escape sequence: ~S",
				scm_list_1 (SCM_MAKE_CHAR (c)));
	      }
	  SCM_STRING_CHARS (*tok_buf)[j] = c;
	  ++j;
	}
      if (j == 0)
	return scm_nullstr;
      SCM_STRING_CHARS (*tok_buf)[j] = 0;
      return scm_mem2string (SCM_STRING_CHARS (*tok_buf), j);

    case '0': case '1': case '2': case '3': case '4':
    case '5': case '6': case '7': case '8': case '9':
    case '.':
    case '-':
    case '+':
    num:
      j = scm_read_token (c, tok_buf, port, 0);
      if (j == 1 && (c == '+' || c == '-'))
	/* Shortcut:  Detected symbol '+ or '- */
	goto tok;

      p = scm_i_mem2number (SCM_STRING_CHARS (*tok_buf), j, 10);
      if (!SCM_FALSEP (p))
	return p;
      if (c == '#')
	{
	  if ((j == 2) && (scm_getc (port) == '('))
	    {
	      scm_ungetc ('(', port);
	      c = SCM_STRING_CHARS (*tok_buf)[1];
	      goto callshrp;
	    }
	  scm_input_error (FUNC_NAME, port, "unknown # object", SCM_EOL);
	}
      goto tok;

    case ':':
      if (SCM_EQ_P (SCM_PACK (SCM_KEYWORD_STYLE), scm_keyword_prefix))
	{
	  j = scm_read_token ('-', tok_buf, port, 0);
	  p = scm_mem2symbol (SCM_STRING_CHARS (*tok_buf), j);
	  return scm_make_keyword_from_dash_symbol (p);
	}
      /* fallthrough */
    default:
#if SCM_ENABLE_ELISP
    read_token:
#endif
      j = scm_read_token (c, tok_buf, port, 0);
      /* fallthrough */

    tok:
      return scm_mem2symbol (SCM_STRING_CHARS (*tok_buf), j);
    }
}
#undef FUNC_NAME


#ifdef _UNICOS
_Pragma ("noopt");		/* # pragma _CRI noopt */
#endif

size_t 
scm_read_token (int ic, SCM *tok_buf, SCM port, int weird)
{
  register size_t j;
  register int c;
  register char *p;

  c = (SCM_CASE_INSENSITIVE_P ? scm_downcase(ic) : ic);
  p = SCM_STRING_CHARS (*tok_buf);

  if (weird)
    j = 0;
  else
    {
      j = 0;
      while (j + 2 >= SCM_STRING_LENGTH (*tok_buf))
	p = scm_grow_tok_buf (tok_buf);
      p[j] = c;
      ++j;
    }

  while (1)
    {
      while (j + 2 >= SCM_STRING_LENGTH (*tok_buf))
	p = scm_grow_tok_buf (tok_buf);
      c = scm_getc (port);
      switch (c)
	{
	case '(':
	case ')':
#if SCM_ENABLE_ELISP
	case '[':
	case ']':
#endif
	case '"':
	case ';':
	case SCM_WHITE_SPACES:
	case SCM_LINE_INCREMENTORS:
	  if (weird
#if SCM_ENABLE_ELISP
	      || ((!SCM_ELISP_VECTORS_P) && ((c == '[') || (c == ']')))
#endif
	      )
	    goto default_case;

	  scm_ungetc (c, port);
	case EOF:
	eof_case:
	  p[j] = 0;
	  return j;
	case '\\':
	  if (!weird)
	    goto default_case;
	  else
	    {
	      c = scm_getc (port);
	      if (c == EOF)
		goto eof_case;
	      else
		goto default_case;
	    }
	case '}':
	  if (!weird)
	    goto default_case;

	  c = scm_getc (port);
	  if (c == '#')
	    {
	      p[j] = 0;
	      return j;
	    }
	  else
	    {
	      scm_ungetc (c, port);
	      c = '}';
	      goto default_case;
	    }

	default:
	default_case:
	  {
	    c = (SCM_CASE_INSENSITIVE_P ? scm_downcase(c) : c);
	    p[j] = c;
	    ++j;
	  }

	}
    }
}

#ifdef _UNICOS
_Pragma ("opt");		/* # pragma _CRI opt */
#endif

static SCM 
scm_i_lreadparen (SCM *tok_buf, SCM port, char *name, SCM *copy, char term_char)
#define FUNC_NAME "scm_i_lreadparen"
{
  SCM tmp;
  SCM tl;
  SCM ans;
  int c;

  c = scm_flush_ws (port, name);
  if (term_char == c)
    return SCM_EOL;
  scm_ungetc (c, port);
  if (SCM_EQ_P (scm_sym_dot, (tmp = scm_lreadr (tok_buf, port, copy))))
    {
      ans = scm_lreadr (tok_buf, port, copy);
    closeit:
      if (term_char != (c = scm_flush_ws (port, name)))
	scm_input_error (FUNC_NAME, port, "missing close paren", SCM_EOL);
      return ans;
    }
  ans = tl = scm_cons (tmp, SCM_EOL);
  while (term_char != (c = scm_flush_ws (port, name)))
    {
      scm_ungetc (c, port);
      if (SCM_EQ_P (scm_sym_dot, (tmp = scm_lreadr (tok_buf, port, copy))))
	{
	  SCM_SETCDR (tl, scm_lreadr (tok_buf, port, copy));
	  goto closeit;
	}
      SCM_SETCDR (tl, scm_cons (tmp, SCM_EOL));
      tl = SCM_CDR (tl);
    }
  return ans;
}
#undef FUNC_NAME


SCM 
scm_lreadrecparen (SCM *tok_buf, SCM port, char *name, SCM *copy)
#define FUNC_NAME "scm_lreadrecparen"
{
  register int c;
  register SCM tmp;
  register SCM tl, tl2 = SCM_EOL;
  SCM ans, ans2 = SCM_EOL;
  /* Need to capture line and column numbers here. */
  int line = SCM_LINUM (port);
  int column = SCM_COL (port) - 1;

  c = scm_flush_ws (port, name);
  if (')' == c)
    return SCM_EOL;
  scm_ungetc (c, port);
  if (SCM_EQ_P (scm_sym_dot, (tmp = scm_lreadr (tok_buf, port, copy))))
    {
      ans = scm_lreadr (tok_buf, port, copy);
      if (')' != (c = scm_flush_ws (port, name)))
	scm_input_error (FUNC_NAME, port, "missing close paren", SCM_EOL);
      return ans;
    }
  /* Build the head of the list structure. */
  ans = tl = scm_cons (tmp, SCM_EOL);
  if (SCM_COPY_SOURCE_P)
    ans2 = tl2 = scm_cons (SCM_CONSP (tmp)
			   ? *copy
			   : tmp,
			   SCM_EOL);
  while (')' != (c = scm_flush_ws (port, name)))
    {
      SCM new_tail;

      scm_ungetc (c, port);
      if (SCM_EQ_P (scm_sym_dot, (tmp = scm_lreadr (tok_buf, port, copy))))
	{
	  SCM_SETCDR (tl, tmp = scm_lreadr (tok_buf, port, copy));
	  if (SCM_COPY_SOURCE_P)
	    SCM_SETCDR (tl2, scm_cons (SCM_CONSP (tmp)
				       ? *copy
				       : tmp,
				       SCM_EOL));
	  if (')' != (c = scm_flush_ws (port, name)))
	    scm_input_error (FUNC_NAME, port, "missing close paren", SCM_EOL);
	  goto exit;
	}

      new_tail = scm_cons (tmp, SCM_EOL);
      SCM_SETCDR (tl, new_tail);
      tl = new_tail;

      if (SCM_COPY_SOURCE_P)
	{
	  SCM new_tail2 = scm_cons (SCM_CONSP (tmp) ? *copy : tmp, SCM_EOL);
	  SCM_SETCDR (tl2, new_tail2);
	  tl2 = new_tail2;
	}
    }
exit:
  scm_whash_insert (scm_source_whash,
		    ans,
		    scm_make_srcprops (line,
				       column,
				       SCM_FILENAME (port),
				       SCM_COPY_SOURCE_P
				       ? *copy = ans2
				       : SCM_UNDEFINED,
				       SCM_EOL));
  return ans;
}
#undef FUNC_NAME




/* Manipulate the read-hash-procedures alist.  This could be written in
   Scheme, but maybe it will also be used by C code during initialisation.  */
SCM_DEFINE (scm_read_hash_extend, "read-hash-extend", 2, 0, 0,
            (SCM chr, SCM proc),
	    "Install the procedure @var{proc} for reading expressions\n"
	    "starting with the character sequence @code{#} and @var{chr}.\n"
	    "@var{proc} will be called with two arguments:  the character\n"
	    "@var{chr} and the port to read further data from. The object\n"
	    "returned will be the return value of @code{read}.")
#define FUNC_NAME s_scm_read_hash_extend
{
  SCM this;
  SCM prev;

  SCM_VALIDATE_CHAR (1, chr);
  SCM_ASSERT (SCM_FALSEP (proc)
	      || SCM_EQ_P (scm_procedure_p (proc), SCM_BOOL_T),
	      proc, SCM_ARG2, FUNC_NAME);

  /* Check if chr is already in the alist.  */
  this = *scm_read_hash_procedures;
  prev = SCM_BOOL_F;
  while (1)
    {
      if (SCM_NULLP (this))
	{
	  /* not found, so add it to the beginning.  */
	  if (!SCM_FALSEP (proc))
	    {
	      *scm_read_hash_procedures = 
		scm_cons (scm_cons (chr, proc), *scm_read_hash_procedures);
	    }
	  break;
	}
      if (SCM_EQ_P (chr, SCM_CAAR (this)))
	{
	  /* already in the alist.  */
	  if (SCM_FALSEP (proc))
	    {
	      /* remove it.  */
	      if (SCM_FALSEP (prev))
		{
		  *scm_read_hash_procedures =
		    SCM_CDR (*scm_read_hash_procedures);
		}
	      else
		scm_set_cdr_x (prev, SCM_CDR (this));
	    }
	  else
	    {
	      /* replace it.  */
	      scm_set_cdr_x (SCM_CAR (this), proc);
	    }
	  break;
	}
      prev = this;
      this = SCM_CDR (this);
    }

  return SCM_UNSPECIFIED;
}
#undef FUNC_NAME

/* Recover the read-hash procedure corresponding to char c.  */
static SCM
scm_get_hash_procedure (int c)
{
  SCM rest = *scm_read_hash_procedures;

  while (1)
    {
      if (SCM_NULLP (rest))
	return SCM_BOOL_F;
  
      if (SCM_CHAR (SCM_CAAR (rest)) == c)
	return SCM_CDAR (rest);
     
      rest = SCM_CDR (rest);
    }
}

void
scm_init_read ()
{
  scm_read_hash_procedures =
    SCM_VARIABLE_LOC (scm_c_define ("read-hash-procedures", SCM_EOL));

  scm_init_opts (scm_read_options, scm_read_opts, SCM_N_READ_OPTIONS);
#include "libguile/read.x"
}

/*
  Local Variables:
  c-file-style: "gnu"
  End:
*/
