/* classes: h_files */

#ifndef SCM_STRPORTS_H
#define SCM_STRPORTS_H

/* Copyright (C) 1995,1996,2000,2001,2002, 2006, 2008, 2010, 2011 Free Software Foundation, Inc.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * as published by the Free Software Foundation; either version 3 of
 * the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
 * 02110-1301 USA
 */



#include "libguile/__scm.h"




#define SCM_STRPORTP(x) \
  (SCM_PORTP (x) && SCM_PORT_TYPE (x) == scm_string_port_type)
#define SCM_OPSTRPORTP(x)    (SCM_STRPORTP (x) && \
                              (SCM_CELL_WORD_0 (x) & SCM_OPN))
#define SCM_OPINSTRPORTP(x)  (SCM_OPSTRPORTP (x) && \
 			      (SCM_CELL_WORD_0 (x) & SCM_RDNG))
#define SCM_OPOUTSTRPORTP(x) (SCM_OPSTRPORTP (x) && \
                              (SCM_CELL_WORD_0 (x) & SCM_WRTNG))



SCM_API scm_t_port_type *scm_string_port_type;



SCM_API SCM scm_mkstrport (SCM pos, SCM str, long modes, const char * caller);
SCM_API SCM scm_strport_to_string (SCM port);
SCM_API SCM scm_object_to_string (SCM obj, SCM printer);
SCM_API SCM scm_call_with_output_string (SCM proc);
SCM_API SCM scm_call_with_input_string (SCM str, SCM proc);
SCM_API SCM scm_open_input_string (SCM str);
SCM_API SCM scm_open_output_string (void);
SCM_API SCM scm_get_output_string (SCM port);
SCM_API SCM scm_c_read_string (const char *expr);
SCM_API SCM scm_c_eval_string (const char *expr);
SCM_API SCM scm_c_eval_string_in_module (const char *expr, SCM module);
SCM_API SCM scm_eval_string (SCM string);
SCM_API SCM scm_eval_string_in_module (SCM string, SCM module);
SCM_INTERNAL void scm_init_strports (void);

#endif  /* SCM_STRPORTS_H */

/*
  Local Variables:
  c-file-style: "gnu"
  End:
*/
