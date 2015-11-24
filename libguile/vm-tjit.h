/* Copyright (C) 2014, 2015 Free Software Foundation, Inc.
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

#ifndef _SCM_VM_TJIT_H_
#define _SCM_VM_TJIT_H_

#include <libguile.h>

enum scm_tjit_vm_state
  {
    SCM_TJIT_VM_STATE_INTERPRET,
    SCM_TJIT_VM_STATE_RECORD,
  };

struct scm_tjit_state
{
  enum scm_tjit_vm_state vm_state; /* current vm state */
  scm_t_uintptr loop_start; /* IP to start a loop */
  scm_t_uintptr loop_end;   /* IP to end a loop */
  scm_t_uint32 bc_idx;      /* current index of traced bytecode */
  scm_t_uint32 *bytecode;   /* buffer to contain traced bytecode */
  SCM traces;               /* scheme list to contain recorded trace. */
  int parent_fragment_id;   /* fragment ID of parent trace, or 0 for root*/
  int parent_exit_id;       /* exit id of parent trace, or 0 for root */
};

typedef SCM (*scm_t_native_code) (scm_i_thread *thread,
                                  struct scm_vm *vp,
                                  scm_i_jmp_buf *registers);

SCM_API SCM scm_tjit_ip_counter (void);
SCM_API SCM scm_tjit_fragment_table (void);
SCM_API SCM scm_tjit_root_trace_table (void);
SCM_API SCM scm_tjit_failed_ip_table (void);
SCM_API SCM scm_tjit_hot_loop (void);
SCM_API SCM scm_set_tjit_hot_loop_x (SCM count);
SCM_API SCM scm_tjit_hot_exit (void);
SCM_API SCM scm_set_tjit_hot_exit_x (SCM count);
SCM_API SCM scm_tjit_max_retries (void);
SCM_API SCM scm_set_tjit_max_retries_x (SCM count);

SCM_API SCM scm_tjit_make_retval (scm_i_thread *thread,
                                  scm_t_bits exit_id,
                                  scm_t_bits exit_ip,
                                  scm_t_bits nlocals);

SCM_API void scm_tjit_dump_retval (SCM tjit_retval, struct scm_vm *vp);
SCM_API void scm_tjit_dump_locals (SCM trace_id, int n,
                                   union scm_vm_stack_element *fp);

/* Fields in record-type `fragment', from:
   "module/system/vm/native/tjit/parameters.scm". */
#define SCM_FRAGMENT_ID(T)             SCM_STRUCT_SLOT_REF (T, 0)
#define SCM_FRAGMENT_CODE(T)           SCM_STRUCT_SLOT_REF (T, 1)
#define SCM_FRAGMENT_EXIT_COUNTS(T)    SCM_STRUCT_SLOT_REF (T, 2)
#define SCM_FRAGMENT_ENTRY_IP(T)       SCM_STRUCT_SLOT_REF (T, 3)
#define SCM_FRAGMENT_PARENT_ID(T)      SCM_STRUCT_SLOT_REF (T, 4)
#define SCM_FRAGMENT_PARENT_EXIT_ID(T) SCM_STRUCT_SLOT_REF (T, 5)
#define SCM_FRAGMENT_LOOP_ADDRESS(T)   SCM_STRUCT_SLOT_REF (T, 6)

#define SCM_TJIT_RETVAL_EXIT_ID(R) SCM_CELL_OBJECT (R, 0)
#define SCM_TJIT_RETVAL_FRAGMENT_ID(R) SCM_CELL_OBJECT (R, 1)
#define SCM_TJIT_RETVAL_NLOCALS(R) SCM_I_INUM (SCM_CELL_OBJECT (R, 2))

SCM_API SCM scm_do_inline_from_double (scm_i_thread *thread, double val);
SCM_API SCM scm_do_inline_cons (scm_i_thread *thread, SCM x, SCM y);

SCM_API void scm_bootstrap_vm_tjit (void);
SCM_API void scm_init_vm_tjit (void);

SCM_INTERNAL struct scm_tjit_state *scm_make_tjit_state (void);

#endif /* _SCM_VM_MJIT_H_ */

/*
  Local Variables:
  c-file-style: "gnu"
  End:
*/
