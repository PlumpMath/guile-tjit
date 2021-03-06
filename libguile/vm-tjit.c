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

#include "_scm.h"
#include "vm-tjit.h"
#include "bdw-gc.h"

/* Internal C macros */

#define OP1(a) 1
#define OP2(a, b) 2
#define OP3(a, b, c) 3
#define OP4(a, b, c, d) 4
#define OP5(a, b, c, d, e) 5
#define OP_DST 0
#define NOP 0

/* Bytecode operation sizes */
static const int op_sizes[256] = {
#define OP_SIZE(opcode, tag, name, meta) meta,
  FOR_EACH_VM_OPERATION (OP_SIZE)
#undef OP_SIZE
};

#undef OP1
#undef OP2
#undef OP3
#undef OP4
#undef OP5
#undef OP_DST
#undef NOP

/* For bytecode IP hash, used to count hot IP, etc. */
#define TJIT_HASH_MASK 0xffffff
#define TJIT_HASH_SIZE ((TJIT_HASH_MASK + 1) / 4)
#define TJIT_HASH_FUNC(ip) ((TJIT_HASH_MASK & ip) >> 2)

#define SCM_TJIT_HASH(name)                                     \
  static scm_t_uint16 name##_hash[TJIT_HASH_SIZE] = { 0 };      \
                                                                \
  static inline scm_t_uint16                                    \
  name##_ref (scm_t_uint32 key)                                 \
  {                                                             \
    return name##_hash[TJIT_HASH_FUNC (key)];                   \
  }                                                             \
                                                                \
  static inline void                                            \
  name##_set (scm_t_uint32 key, scm_t_uint16 val)               \
  {                                                             \
    name##_hash[TJIT_HASH_FUNC (key)] = val;                    \
  }

#define SCM_TJIT_PARAM(name, sname, ini)                                \
                                                                        \
  static SCM tjit_##name = SCM_I_MAKINUM (ini);                         \
                                                                        \
  SCM_DEFINE (scm_tjit_##name, "tjit-"#sname, 0, 0, 0, (void), "")      \
  {                                                                     \
    return tjit_##name;                                                 \
  }                                                                     \
                                                                        \
  SCM_DEFINE (scm_set_tjit_##name##_x, "set-tjit-"#sname"!",            \
              1, 0, 0, (SCM val), "")                                   \
  {                                                                     \
    /* XXX: Some params does not need `65536 < val' check. */           \
    if (SCM_I_NINUMP (val)                                              \
        || val < 0                                                      \
        || SCM_I_MAKINUM (65536) < val)                                 \
      scm_misc_error ("set-tjit-"#sname"!",                             \
                      "Invalid arg: ~s", scm_list_1 (val));             \
                                                                        \
    tjit_##name = val;                                                  \
    return SCM_UNSPECIFIED;                                             \
  }

#define SCM_TJIT_TABLE(name, sname)                                     \
                                                                        \
  static SCM tjit_##name##_table;                                       \
                                                                        \
  SCM_DEFINE (scm_tjit_##name, "tjit-"#sname, 0, 0, 0, (void), "")      \
  {                                                                     \
   return tjit_##name##_table;                                          \
  }

#define SCM_TJITC(loop_p)                 \
  do {                                    \
    vp->ip = ip;                          \
    tjitc (tj, s_ip, loop_p);             \
    stop_recording (tj);                  \
    return vp->sp;                        \
  } while (0)

#define SCM_DOWNREC_P(fragmeng)                         \
  (scm_is_true (fragment) && scm_is_true (SCM_FRAGMENT_DOWNREC_P (fragment)))

#define SCM_UPREC_P(fragment)                   \
  (scm_is_true (fragment) && scm_is_true (SCM_FRAGMENT_UPREC_P (fragment)))

#define TJIT_INC_JUMP   1
#define TJIT_INC_CALL   1
#define TJIT_INC_TCALL  1
#define TJIT_INC_RETURN 1


/*
 * Configurable parameters
 */

/* Number of iterations to decide a hot loop. */
SCM_TJIT_PARAM (hot_loop, hot-loop, 59)

/* Number of exits to decide a hot side exit. */
SCM_TJIT_PARAM (hot_exit, hot-exit, 40)

/* Maximum length of traced bytecodes. */
SCM_TJIT_PARAM (max_record, max-record, 5000)

/* Maximum count of retries for failed compilation. */
SCM_TJIT_PARAM (max_retries, max-retries, 10)

/* Maximum number of side traces from root trace. */
SCM_TJIT_PARAM (max_sides, max-sides, 100)

/* Maximum number to try compiling a side trace. */
SCM_TJIT_PARAM (try_sides, try-sides, 4)

/* Number of recursive procedure calls to unroll. */
SCM_TJIT_PARAM (num_unrolls, num-unrolls, 2)

/* VM engine used for Scheme procedure call. */
SCM_TJIT_PARAM (scheme_engine, scheme-engine, SCM_VM_REGULAR_ENGINE)


/*
 *  Internal variables
 */

/* Hash array to hold iteration counts for loops. Key is bytecode IP,
   value is current count. */
SCM_TJIT_HASH (hot_ip)

/* Hash array to hold IP of root traces. Key is bytecode IP, value is 0
   or 1. */
SCM_TJIT_HASH (root_ip)

/* Hash array to hold IPs of failed traces. Key is bytecode IP, value is
   number of failed compilation. */
SCM_TJIT_HASH (failed_ip)

/* Hash table to hold all fragments. Key is fragment ID, value is
   fragment data. */
SCM_TJIT_TABLE (fragment, fragment);

/* Hash table to hold fragment data of root traces. Key is bytecode IP,
   value is fragment data. */
SCM_TJIT_TABLE (root_trace, root-trace);

/* Fluid to hold tjit state. */
static SCM tjit_state_fluid;

/* Variable to hold Scheme procedure tjitc. */
static SCM tjitc_var;

/* Initial trace id, increment after native compilation. */
static int tjit_trace_id = 1;


/*
 * Internal functions
 */

static inline void
tjitc (struct scm_tjit_state *tj, SCM linked_ip, SCM loop_p)
{
  if (scm_is_null (tj->traces))
    {
      scm_t_uint16 count = failed_ip_ref (tj->loop_start);
      failed_ip_set (tj->loop_start, count + 1);
    }
  else
    {
      SCM s_bytecode, downrec_p, uprec_p;

      s_bytecode =
        scm_c_take_gc_bytevector ((signed char *) tj->bytecode,
                                  tj->bc_idx * sizeof (scm_t_uint32),
                                  SCM_BOOL_F);
      downrec_p =
        tj->trace_type == SCM_TJIT_TRACE_CALL ? SCM_BOOL_T : SCM_BOOL_F;
      uprec_p =
        tj->trace_type == SCM_TJIT_TRACE_RETURN ? SCM_BOOL_T : SCM_BOOL_F;

      scm_c_set_vm_engine_x (SCM_I_INUM (tjit_scheme_engine));
      scm_call_9 (tjitc_var, SCM_I_MAKINUM (tjit_trace_id), s_bytecode,
                  scm_reverse_x (tj->traces, SCM_EOL),
                  tj->parent_fragment_id ?
                  tj->parent_fragment_id : SCM_BOOL_F,
                  tj->parent_exit_id ?
                  tj->parent_exit_id : SCM_BOOL_F,
                  linked_ip, loop_p, downrec_p, uprec_p);
      scm_c_set_vm_engine_x (SCM_VM_TJIT_ENGINE);
    }
}

static inline void
start_recording (struct scm_tjit_state *tj,
                 scm_t_uint32 *start, scm_t_uint32 *end,
                 enum scm_tjit_trace_type trace_type)
{
  tj->vm_state = SCM_TJIT_VM_STATE_RECORD;
  tj->trace_type = trace_type;
  tj->loop_start = (scm_t_uintptr) start;
  tj->loop_end = (scm_t_uintptr) end;
}

static inline void
stop_recording (struct scm_tjit_state *tj)
{
  tj->vm_state = SCM_TJIT_VM_STATE_INTERPRET;
  tj->traces = SCM_EOL;
  tj->bc_idx = 0;
  tj->parent_fragment_id = 0;
  tj->parent_exit_id = 0;
  tj->nunrolled = 0;
}

static inline void
abort_recording (struct scm_tjit_state *tj, scm_t_uint32 *ip)
{
  scm_t_uint16 retries = failed_ip_ref ((scm_t_uintptr) ip);
  failed_ip_set ((scm_t_uintptr) ip, retries + 1);
  stop_recording (tj);
}

static inline void
record (struct scm_tjit_state *tj, scm_i_thread *thread, struct scm_vm *vp,
        scm_t_uint32 *ip, union scm_vm_stack_element *sp)
{
  int opcode, i, num_locals;
  SCM locals, trace;
  SCM s_ra = SCM_I_MAKINUM (SCM_FRAME_RETURN_ADDRESS (vp->fp));
  SCM s_dl_diff = SCM_I_MAKINUM (vp->fp[1].as_uint);
  SCM s_ip = SCM_I_MAKINUM (ip);

  opcode = *ip & 0xff;

  /* Store current bytecode. */
  for (i = 0; i < op_sizes[opcode]; ++i, ++tj->bc_idx)
    tj->bytecode[tj->bc_idx] = ip[i];

  /* Copy local contents to vector. */
  num_locals = FRAME_LOCALS_COUNT ();
  locals = scm_inline_words (thread, (num_locals << 8) | scm_tc7_vector,
                             num_locals + 1);
  for (i = 0; i < num_locals; ++i)
    SCM_SIMPLE_VECTOR_SET (locals, i, sp[i].as_scm);

  /* Save other data to vector. */
  trace = scm_inline_words (thread, (5 << 8) | scm_tc7_vector, 5 + 1);
  SCM_SIMPLE_VECTOR_SET (trace, 0, SCM_BOOL_F);
  SCM_SIMPLE_VECTOR_SET (trace, 1, s_ip);
  SCM_SIMPLE_VECTOR_SET (trace, 2, s_ra);
  SCM_SIMPLE_VECTOR_SET (trace, 3, s_dl_diff);
  SCM_SIMPLE_VECTOR_SET (trace, 4, locals);

  tj->traces = scm_inline_cons (thread, trace, tj->traces);
}

static inline SCM
tjit_matching_fragment_inner (SCM locals, SCM fragments)
{
  while (scm_is_pair (fragments))
    {
      SCM type_checker, fragment;
      fragment = SCM_CAR (fragments);
      type_checker = SCM_FRAGMENT_TYPE_CHECKER (fragment);
      if (scm_is_true (scm_call_1 (type_checker, locals)))
        return fragment;
      else
        fragments = SCM_CDR (fragments);
    }
  return SCM_BOOL_F;
}

static inline SCM
tjit_matching_fragment (scm_i_thread *thread, struct scm_vm *vp, SCM s_ip)
{
  int i, nlocals;
  SCM ret, locals;
  union scm_vm_stack_element *sp;

  sp = vp->sp;
  ret = scm_hashq_ref (tjit_root_trace_table, s_ip, SCM_BOOL_F);

  if (scm_is_false (ret))
    return ret;

  nlocals = FRAME_LOCALS_COUNT ();
  locals = scm_inline_words (thread, nlocals << 8 | scm_tc7_vector,
                             nlocals + 1);

  for (i = 0; i < nlocals; ++i)
    SCM_SIMPLE_VECTOR_SET (locals, i, sp[i].as_scm);

  scm_c_set_vm_engine_x (SCM_I_INUM (tjit_scheme_engine));
  ret = tjit_matching_fragment_inner (locals, ret);
  scm_c_set_vm_engine_x (SCM_VM_TJIT_ENGINE);

  return ret;
}

static inline union scm_vm_stack_element*
tjit_merge (scm_t_uint32 *ip, union scm_vm_stack_element *sp,
            scm_i_thread *thread, struct scm_vm *vp,
            struct scm_tjit_state *tj)
{
  SCM fragment;
  int link_found;

  SCM s_ip = SCM_I_MAKINUM (ip);
  scm_t_uint32 *start_ip = (scm_t_uint32 *) tj->loop_start;
  scm_t_uint32 *end_ip = (scm_t_uint32 *) tj->loop_end;
  int has_root_trace = root_ip_ref ((scm_t_uintptr) ip);

  if (has_root_trace)
    {
      vp->ip = ip;
      fragment = tjit_matching_fragment (thread, vp, s_ip);
      sp = vp->sp;
    }
  else
    fragment = SCM_BOOL_F;

  /* Avoid looking up fragment of looping-side-trace itself. */
  link_found = has_root_trace && ip != start_ip;

  switch (tj->trace_type)
    {
    case SCM_TJIT_TRACE_SIDE:
      if (scm_is_true (fragment))
        SCM_TJITC (SCM_BOOL_F);
      else
        record (tj, thread, vp, ip, sp);
      break;

    case SCM_TJIT_TRACE_JUMP:
    case SCM_TJIT_TRACE_TCALL:
      if (ip == end_ip)
        {
          record (tj, thread, vp, ip, sp);
          SCM_TJITC (SCM_BOOL_T);
        }
      else if (scm_is_true (fragment))
        abort_recording (tj, start_ip);
      else
        record (tj, thread, vp, ip, sp);
      break;

    case SCM_TJIT_TRACE_CALL:
      if (ip == start_ip || (link_found && SCM_DOWNREC_P (fragment)))
        {
          if (SCM_I_INUM (tjit_num_unrolls) <= tj->nunrolled)
            {
              if (link_found)
                abort_recording (tj, start_ip);
              else
                SCM_TJITC (SCM_BOOL_T);
            }
          else
            {
              record (tj, thread, vp, ip, sp);
              ++(tj->nunrolled);
            }
        }
      else if (ip == end_ip)
        /* XXX: Hot procedure call, possibly non-recursive. May worth to
           compile but currently ignored. */
        stop_recording (tj);
      else
        record (tj, thread, vp, ip, sp);
      break;

    case SCM_TJIT_TRACE_RETURN:
      if (ip == start_ip || (link_found && SCM_UPREC_P (fragment)))
        {
          if (tj->nunrolled == SCM_I_INUM (tjit_num_unrolls))
            SCM_TJITC (link_found ? SCM_BOOL_F : SCM_BOOL_T);
          else
            {
              record (tj, thread, vp, ip, sp);
              ++(tj->nunrolled);
            }
        }
      else if (ip == end_ip)
        /* XXX: Hot procedure return, possibly non-recursive. */
        stop_recording (tj);
      else
        record (tj, thread, vp, ip, sp);
      break;

    default:
      break;
    }
  return sp;
}

static inline void
call_native (SCM fragment, scm_i_thread *thread, struct scm_vm *vp,
             scm_i_jmp_buf *registers, struct scm_tjit_state *tj)
{
  SCM s_ip, code, origin, exit_counts, count, ret_fragment;
  size_t max_retries, exit_id;
  scm_t_native_code fn;
  int retval;

  s_ip = SCM_FRAGMENT_ENTRY_IP (fragment);
  code = SCM_FRAGMENT_CODE (fragment);
  fn = (scm_t_native_code) SCM_BYTEVECTOR_CONTENTS (code);

  /* Run the native code. */
  retval = fn (thread, vp, registers);

  /* Back to interpreter. Native code sets some of the fields in tj
     during bailout, using them to decide what to do next. */
  if (retval)
    {
      origin = SCM_PACK (tj->ret_origin);
      ret_fragment = SCM_PACK (tj->ret_fragment);
      exit_id = tj->ret_exit_id;
      exit_counts = SCM_FRAGMENT_EXIT_COUNTS (ret_fragment);
      count = SCM_SIMPLE_VECTOR_REF (exit_counts, exit_id);
      max_retries = SCM_I_INUM (tjit_hot_exit) + SCM_I_INUM (tjit_try_sides);

      if (SCM_I_INUM (count) < max_retries
          && SCM_FRAGMENT_NUM_CHILD (origin) < tjit_max_sides)
        {
          count = SCM_PACK (SCM_UNPACK (count) + INUM_STEP);
          SCM_SIMPLE_VECTOR_SET (exit_counts, exit_id, count);

          if (tjit_hot_exit < count)
            {
              scm_t_uint32 *start = vp->ip;
              scm_t_uint32 *end = (scm_t_uint32 *) SCM_I_INUM (s_ip);

              tj->parent_fragment_id = SCM_FRAGMENT_ID (ret_fragment);
              tj->parent_exit_id = SCM_I_MAKINUM (exit_id);
              start_recording (tj, start, end, SCM_TJIT_TRACE_SIDE);
            }
        }
    }

 /* Tell GC to keep fields in VP. */
  scm_remember_upto_here_1 (SCM_PACK_POINTER (vp->ip));
  scm_remember_upto_here_1 (SCM_PACK_POINTER (vp->sp));
  scm_remember_upto_here_1 (SCM_PACK_POINTER (vp->fp));
}

static inline struct scm_tjit_state*
scm_make_tjit_state (void)
{
  size_t bytes;
  struct scm_tjit_state *t;

  bytes = sizeof (scm_t_uint32 *) * SCM_I_INUM (tjit_max_record) * 5;

  t = scm_gc_malloc (sizeof (struct scm_tjit_state), "tjitstate");
  t->vm_state = SCM_TJIT_VM_STATE_INTERPRET;
  t->trace_type = SCM_TJIT_TRACE_JUMP;
  t->loop_start = 0;
  t->loop_end = 0;
  t->bc_idx = 0;
  t->bytecode =
    scm_inline_gc_malloc_pointerless (SCM_I_CURRENT_THREAD, bytes);
  t->traces = SCM_EOL;
  t->parent_fragment_id = 0;
  t->parent_exit_id = 0;
  t->nunrolled = 0;
  t->ret_exit_id = 0;
  t->ret_fragment = 0;
  t->ret_origin = 0;

  return t;
}

static inline struct scm_tjit_state*
scm_acquire_tjit_state (void)
{
  SCM tj = scm_fluid_ref (tjit_state_fluid);

  if (scm_is_false (tj))
    {
      struct scm_tjit_state *new_tj = scm_make_tjit_state ();

      scm_fluid_set_x (tjit_state_fluid, SCM_PACK (new_tj));

      return new_tj;
    }
  else
    return (struct scm_tjit_state *) SCM_UNPACK (tj);
}


/* C macros for vm-tjit engine

  These two macros were perviously defined as static inline functions.
  Though the static functions had some problems with garbage collector,
  sometimes fp was gabage collected after invoking native function.
  Hence rewritten as C macro to avoid this issue.  This file is included
  by "libguile/vm.c". Following two macros share common variables
  defined in "libguile/vm-engine.h", such as thread, vp, ip, ... etc. */

#define SCM_TJIT_ENTER(JUMP, END, TTYPE, INC)                           \
  do {                                                                  \
    scm_t_uintptr next_ip = (scm_t_uintptr) (ip + JUMP);                \
                                                                        \
    if (root_ip_ref (next_ip))                                          \
      {                                                                 \
        SCM s_ip, fragment;                                             \
                                                                        \
        s_ip = SCM_I_MAKINUM (next_ip);                                 \
        SYNC_IP ();                                                     \
        fragment = tjit_matching_fragment (thread, vp, s_ip);           \
        CACHE_SP ();                                                    \
        if (scm_is_true (fragment))                                     \
          {                                                             \
            /* Call native code, update ip and sp variables in C, */    \
            /* and jump to the IP set by the native code. */            \
            call_native (fragment, thread, vp, registers, tj);          \
            CACHE_REGISTER ();                                          \
            NEXT (0);                                                   \
          }                                                             \
      }                                                                 \
                                                                        \
    /* Increment hot ip counter unless current IP is black-listed. */   \
    if (failed_ip_ref (next_ip) < SCM_I_INUM (tjit_max_retries))        \
      {                                                                 \
        scm_t_uint16 count = hot_ip_ref (next_ip);                      \
        if (tjit_hot_loop < SCM_I_MAKINUM (count))                      \
          {                                                             \
            scm_t_uint32 *start = (scm_t_uint32 *) next_ip;             \
            start_recording (tj, start, END, TTYPE);                    \
            hot_ip_set (next_ip, 0);                                    \
          }                                                             \
        else                                                            \
          hot_ip_set (next_ip, count + INC);                            \
      }                                                                 \
                                                                        \
    /* Jump to the IP specified by JUMP parameter. */                   \
    NEXT (JUMP);                                                        \
  } while (0)

#define SCM_TJIT_MERGE()                                                \
  do {                                                                  \
    sp = tjit_merge (ip, sp, thread, vp, tj);                           \
    if (SCM_I_INUM (tjit_max_record) < tj->bc_idx)                      \
      abort_recording (tj, (scm_t_uint32 *) tj->loop_start);            \
  } while (0)


/*
 * Scheme interfaces
 */

SCM_DEFINE (scm_tjit_increment_id_x, "tjit-increment-id!", 0, 0, 0,
            (void), "Increment trace ID.")
#define FUNC_NAME s_scm_tjit_increment_id_x
{
  ++tjit_trace_id;
  return SCM_UNSPECIFIED;
}
#undef FUNC_NAME

SCM_DEFINE (scm_tjit_increment_compilation_failure_x,
            "tjit-increment-compilation-failure!", 2, 0, 0,
            (SCM ip, SCM inc), "Increment compilation failure.")
#define FUNC_NAME s_scm_tjit_increment_compilation_failure_x
{
  scm_t_uint32 key = SCM_I_INUM (ip);
  failed_ip_set (key, failed_ip_ref (key) + SCM_I_INUM (inc));
  return SCM_UNSPECIFIED;
}
#undef FUNC_NAME

SCM_DEFINE (scm_tjit_add_root_ip_x, "tjit-add-root-ip!", 1, 0, 0,
            (SCM ip), "Add root trace IP.")
#define FUNC_NAME s_scm_tjit_add_root_ip_x
{
  root_ip_set (SCM_I_INUM (ip), 1);
  return SCM_UNSPECIFIED;
}
#undef FUNC_NAME

SCM_DEFINE (scm_tjit_remove_root_ip_x, "tjit-remove-root-ip!",
            1, 0, 0, (SCM ip), "Remove root trace IP.")
#define FUNC_NAME s_scm_tit_remove_root_ip_x
{
  root_ip_set (SCM_I_INUM (ip), 0);
  return SCM_UNSPECIFIED;
}
#undef FUNC_NAME

SCM_DEFINE (scm_make_negative_pointer, "make-negative-pointer", 1, 0, 0,
            (SCM amount),
            "Make negative address pointer from negative AMOUNT.\n"
            "The amount needs to be negative small integer with tc2=1.")
#define FUNC_NAME s_scm_make_negative_pointer
{
  scm_t_uintptr c_address;

#if SCM_SIZEOF_SCM_T_PTRDIFF == 4
#define BASE_ADDR 0xffffffff
#else
#if SCM_SIZEOF_SCM_T_PTRDIFF == 8
#define BASE_ADDR 0xffffffffffffffff
#else
#error sizeof(scm_t_ptrdiff) is not 4 or 8.
#endif
#endif
  c_address = BASE_ADDR + SCM_I_INUM (amount) + 1;
#undef BASE_ADDR

  return scm_from_pointer ((void *) c_address, NULL);

}
#undef FUNC_NAME

SCM_DEFINE (scm_continuation_next_ip, "continuation-next-ip", 1, 0, 0,
            (SCM cont),
            "Returns next IP of continuation.")
#define FUNC_NAME s_scm_continuation_next_ip
{
  struct scm_vm_cont *cp;

  cp = SCM_VM_CONT_DATA (scm_i_contregs_vm_cont (cont));

  return SCM_I_MAKINUM (cp->ra);
}
#undef FUNC_NAME


/*
 * Gluing functions
 *
 * Following functions are not called from Scheme code, but inlined and
 * called from JIT compiled native code.
 */

void
scm_set_tjit_retval (size_t exit_id, scm_t_bits fragment, scm_t_bits origin)
{
  struct scm_tjit_state *tj = scm_acquire_tjit_state ();

  tj->ret_exit_id = exit_id;
  tj->ret_fragment = fragment;
  tj->ret_origin = origin;
}

static inline SCM
to_hex (SCM n)
{
  return scm_number_to_string (n, SCM_I_MAKINUM (16));
}

void
scm_tjit_dump_retval (struct scm_vm *vp)
{
  SCM port = scm_current_output_port ();
  struct scm_tjit_state *tj = scm_acquire_tjit_state ();

  scm_puts (";;; trace ", port);
  scm_display (SCM_FRAGMENT_ID (SCM_PACK (tj->ret_fragment)), port);
  scm_puts (": exit ", port);
  scm_display (SCM_I_MAKINUM (tj->ret_exit_id), port);
  scm_puts (" => ", port);
  scm_display (to_hex (SCM_I_MAKINUM (vp->ip)), port);
  scm_newline (port);
}

void
scm_tjit_dump_locals (SCM trace_id, int n, struct scm_vm *vp)
{
  int i;
  SCM port = scm_current_output_port ();

  scm_puts (";;; trace ", port);
  scm_display (trace_id, port);
  scm_puts (": sp=", port);
  scm_display (to_hex (SCM_I_MAKINUM (vp->sp)), port);
  scm_puts (" fp=", port);
  scm_display (to_hex (SCM_I_MAKINUM (vp->fp)), port);
  scm_puts (" ra=", port);
  scm_display (to_hex (SCM_I_MAKINUM (vp->fp[0].as_ptr)), port);
  scm_puts (" dl=", port);
  scm_display (to_hex (SCM_I_MAKINUM (vp->fp[1].as_ptr)), port);
  scm_newline (port);

  scm_puts (";;; trace ", port);
  scm_display (trace_id, port);
  scm_puts (": locals", port);
  for (i = 0; i < n; ++i)
    {
      scm_puts(" [", port);
      scm_display (SCM_I_MAKINUM (i), port);
      scm_puts ("]: 0x", port);
      scm_display (to_hex (SCM_I_MAKINUM (vp->sp[i].as_uint)), port);
    }

  scm_newline (port);
}

SCM
scm_do_inline_from_double (scm_i_thread *thread, double val)
{
  SCM z;

  z = SCM_PACK_POINTER
    (scm_inline_gc_malloc_pointerless (thread, sizeof (scm_t_double)));

  SCM_SET_CELL_TYPE (z, scm_tc16_real);
  SCM_REAL_VALUE (z) = val;

  return z;
}

SCM
scm_do_inline_cell (scm_i_thread *thread, scm_t_bits x, scm_t_bits y)
{
  return scm_inline_cell (thread, x, y);
}

SCM
scm_do_inline_words (scm_i_thread *thread, scm_t_bits car,
                     scm_t_uint32 words)
{
  return scm_inline_words (thread, car, words);
}

SCM
scm_do_i_string_ref (SCM str, size_t idx)
{
  scm_t_wchar ch = scm_i_string_ref (str, idx);
  return SCM_MAKE_CHAR (ch);
}

SCM
scm_do_make_continuation (scm_i_thread *thread, struct scm_vm *vp)
{
  SCM vm_cont, cont;
  scm_t_dynstack *dynstack;
  int first;

  dynstack = scm_dynstack_capture_all (&thread->dynstack);
  vm_cont = scm_i_vm_capture_stack (vp->stack_top,
                                    SCM_FRAME_DYNAMIC_LINK (vp->fp),
                                    SCM_FRAME_PREVIOUS_SP (vp->fp),
                                    SCM_FRAME_RETURN_ADDRESS (vp->fp),
                                    dynstack,
                                    0);
  cont = scm_i_make_continuation (&first, vp, vm_cont);

  return cont;
}

SCM
scm_do_return_to_continuation (SCM cont, size_t n,
                               union scm_vm_stack_element *argv)
{
  scm_t_contregs *contregs;

  scm_i_check_continuation (cont);
  contregs = (scm_t_contregs *) SCM_SMOB_DATA_1 (cont);
  vm_return_to_continuation (contregs->vp, contregs->vm_cont, n, argv);

  /* Using SCM_I_LONGJMP. */
  scm_i_reinstate_continuation (cont);

  /* Never reached. */
  return SCM_UNDEFINED;
}

void
scm_do_vm_expand_stack (struct scm_vm *vp, union scm_vm_stack_element *new_sp)
{
  vm_expand_stack (vp, new_sp);
}


/*
 * GDB JIT Interface
 */

typedef enum
  {
    GDB_JIT_NOACTION = 0,
    GDB_JIT_REGISTER,
    GDB_JIT_UNREGISTER
  } jit_actions_t;

struct gdb_jit_entry
{
  struct gdb_jit_entry *next_entry;
  struct gdb_jit_entry *prev_entry;
  const char *symfile_addr;
  uint64_t symfile_size;
};

struct gdb_jit_descriptor
{
  uint32_t version;
  uint32_t action_flag;
  struct gdb_jit_entry *relevant_entry;
  struct gdb_jit_entry *first_entry;
};

void SCM_NOINLINE __jit_debug_register_code (void);

void SCM_NOINLINE
__jit_debug_register_code (void)
{
#ifdef __GNUC__
  __asm__ volatile ("" : : : "memory");
#else
  scm_remember_upto_here_1 (SCM_BOOL_F);
#endif
}

struct gdb_jit_descriptor __jit_debug_descriptor = {
  1, GDB_JIT_NOACTION, NULL, NULL
};

static SCM gdb_jit_entries = SCM_EOL;

SCM_DEFINE (scm_tjit_register_gdb_jit_entry_x, "tjit-register-gdb-jit-entry!",
            1, 0, 0, (SCM elf), "Register GDB JIT entry.")
#define FUNC_NAME s_scm_tjit_register_gdb_jit_entry_x
{
  struct gdb_jit_entry *entry;
  SCM s_entry;

  SCM_VALIDATE_BYTEVECTOR (1, elf);

  entry = scm_gc_malloc (sizeof (struct gdb_jit_entry), "gdbjit");
  entry->prev_entry = NULL;
  entry->next_entry = __jit_debug_descriptor.first_entry;
  if (entry->next_entry)
    entry->next_entry->prev_entry = entry;
  entry->symfile_addr = (const char *) SCM_BYTEVECTOR_CONTENTS (elf);
  entry->symfile_size = SCM_BYTEVECTOR_LENGTH (elf);

  SCM_CRITICAL_SECTION_START;
  __jit_debug_descriptor.first_entry = entry;
  __jit_debug_descriptor.relevant_entry = entry;
  __jit_debug_descriptor.action_flag = GDB_JIT_REGISTER;
  __jit_debug_register_code ();
  SCM_CRITICAL_SECTION_END;

  s_entry = scm_from_pointer (entry, NULL);
  gdb_jit_entries = scm_cons (s_entry, gdb_jit_entries);

  return s_entry;
}
#undef FUNC_NAME

static inline void scm_tjit_unregister_gdb_jit_entry (void *obj)
{
  struct gdb_jit_entry *entry;

  entry = (struct gdb_jit_entry *) obj;
  if (entry->prev_entry)
    entry->prev_entry->next_entry = entry->next_entry;
  else
    __jit_debug_descriptor.first_entry = entry->next_entry;
  if (entry->next_entry)
    entry->next_entry->prev_entry = entry->prev_entry;
  __jit_debug_descriptor.relevant_entry = entry;
  __jit_debug_descriptor.action_flag = GDB_JIT_UNREGISTER;
  __jit_debug_register_code ();
}

static void scm_tjit_cleanup_gdb_entries (void)
{
  SCM_CRITICAL_SECTION_START;
  while (scm_is_pair (gdb_jit_entries))
    {
      void *entry = SCM_POINTER_VALUE (SCM_CAR (gdb_jit_entries));
      scm_tjit_unregister_gdb_jit_entry (entry);
      gdb_jit_entries = SCM_CDR (gdb_jit_entries);
    }
  SCM_CRITICAL_SECTION_END;
}


/*
 * Initialization
 */

void
scm_bootstrap_vm_tjit(void)
{
  tjit_state_fluid = scm_make_fluid ();
  tjit_fragment_table = scm_c_make_hash_table (31);
  tjit_root_trace_table = scm_c_make_hash_table (31);
  tjitc_var = SCM_VARIABLE_REF (scm_c_lookup ("tjitc"));
  atexit (scm_tjit_cleanup_gdb_entries);
}

void
scm_init_vm_tjit (void)
{
#ifndef SCM_MAGIC_SNARFER
#include "libguile/vm-tjit.x"
#endif

  GC_exclude_static_roots (hot_ip_hash, hot_ip_hash + TJIT_HASH_SIZE);
  GC_exclude_static_roots (root_ip_hash, root_ip_hash + TJIT_HASH_SIZE);
  GC_exclude_static_roots (failed_ip_hash, failed_ip_hash + TJIT_HASH_SIZE);
  GC_expand_hp (1024 * 1024 * SIZEOF_SCM_T_BITS);

  /* Define gsubr for non fixnum or flonum arithmetic. */
  scm_c_define_gsubr ("%cadd", 2, 0, 0, scm_sum);
  scm_c_define_gsubr ("%csub", 2, 0, 0, scm_difference);
  scm_c_define_gsubr ("%cmul", 2, 0, 0, scm_product);
  scm_c_define_gsubr ("%cdiv", 2, 0, 0, scm_divide);
  scm_c_define_gsubr ("%cquo", 2, 0, 0, scm_quotient);
  scm_c_define_gsubr ("%crem", 2, 0, 0, scm_remainder);
  scm_c_define_gsubr ("%cmod", 2, 0, 0, scm_modulo);
  scm_c_define_gsubr ("%ceq", 2, 0, 0, scm_num_eq_p);
  scm_c_define_gsubr ("%clt", 2, 0, 0, scm_less_p);
  scm_c_define_gsubr ("%cle", 2, 0, 0, scm_leq_p);
  scm_c_define_gsubr ("%cgt", 2, 0, 0, scm_gr_p);
  scm_c_define_gsubr ("%cge", 2, 0, 0, scm_geq_p);

  /* Note that the second argument of `scm_do_i_string_ref' is size_t,
     not SCM type. */
  scm_c_define_gsubr ("scm-do-i-string-ref", 2, 0, 0, scm_do_i_string_ref);
}

/*
  Local Variables:
  c-file-style: "gnu"
  End:
*/
