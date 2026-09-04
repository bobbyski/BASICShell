; basicc — q1, traditional dialect
target triple = "arm64-apple-macosx16.0"

declare void @basic_rt_start()
declare void @basic_rt_finish()
declare void @basic_rt_fail(ptr)
declare void @basic_rt_fail_type(ptr)
declare void @basic_rt_fail_missing(ptr)
declare void @basic_rt_gosub_push(i64)
declare i64 @basic_rt_gosub_pop()
declare i64 @basic_rt_gosub_depth()
declare void @basic_rt_randomize(double)
declare void @basic_rt_randomize_time()
declare double @basic_rt_rnd()
declare void @basic_rt_print_text(ptr)
declare void @basic_rt_print_number(double)
declare void @basic_rt_print_boolean(i1)
declare void @basic_rt_print_comma()
declare void @basic_rt_print_tab(double)
declare void @basic_rt_print_spc(double)
declare void @basic_rt_print_newline()
declare double @basic_rt_input_number(ptr, ptr)
declare ptr @basic_rt_input_string(ptr, ptr)
declare i1 @basic_rt_input_boolean(ptr, ptr)
declare i1 @basic_rt_file_input_boolean(double)
declare ptr @basic_rt_line_input(ptr)
declare ptr @basic_rt_number_text(double)
declare void @basic_rt_using_begin(ptr)
declare void @basic_rt_using_number(double)
declare void @basic_rt_using_string(ptr)
declare void @basic_rt_using_end(i1)
declare ptr @basic_rt_using_render()
declare ptr @basic_rt_string_literal(ptr, i64)
declare void @basic_rt_string_retain(ptr)
declare void @basic_rt_string_release(ptr)
declare ptr @basic_rt_string_concat(ptr, ptr)
declare i1 @basic_rt_string_equal(ptr, ptr)
declare i1 @basic_rt_string_less(ptr, ptr)
declare i1 @basic_rt_string_truthy(ptr)
declare double @basic_rt_string_length(ptr)
declare double @basic_rt_string_asc(ptr)
declare double @basic_rt_string_val(ptr)
declare double @basic_rt_string_instr(double, ptr, ptr)
declare ptr @basic_rt_number_str(double)
declare ptr @basic_rt_chr(double)
declare ptr @basic_rt_string_left(ptr, double)
declare ptr @basic_rt_string_right(ptr, double)
declare ptr @basic_rt_string_mid(ptr, double, double)
declare ptr @basic_rt_space(double)
declare ptr @basic_rt_string_repeat(double, ptr)
declare ptr @basic_rt_write_quote(ptr)
declare ptr @basic_rt_array_dim(i64, ptr, i64, i64)
declare ptr @basic_rt_array_load_composite(ptr, i64)
declare void @basic_rt_array_store_composite(ptr, i64, ptr)
declare void @basic_rt_type_register(i64, ptr)
declare i1 @basic_rt_composite_get_boolean(ptr, i64)
declare void @basic_rt_composite_set_boolean(ptr, i64, i1)
declare ptr @basic_rt_composite_get_array(ptr, i64)
declare void @basic_rt_composite_set_array(ptr, i64, ptr, ptr)
declare ptr @basic_rt_composite_get_value(ptr, i64)
declare void @basic_rt_composite_set_value(ptr, i64, ptr, ptr)
declare ptr @basic_rt_composite_get_dictionary(ptr, i64)
declare double @basic_rt_array_count(ptr, ptr)
declare void @basic_rt_array_assign(ptr, ptr, ptr)
declare i1 @basic_rt_array_load_boolean(ptr, i64)
declare void @basic_rt_array_store_boolean(ptr, i64, i1)
declare ptr @basic_rt_array_load_value(ptr, i64)
declare void @basic_rt_array_store_value(ptr, i64, ptr, ptr)
declare ptr @basic_rt_array_load_dictionary(ptr, i64)
declare void @basic_rt_print_array(ptr, ptr)
declare ptr @basic_rt_array_text(ptr, ptr)
declare void @basic_rt_value_release(ptr)
declare ptr @basic_rt_value_copy(ptr)
declare ptr @basic_rt_value_store(ptr, ptr, ptr)
declare ptr @basic_rt_value_empty()
declare ptr @basic_rt_value_null()
declare ptr @basic_rt_value_from_number(double)
declare ptr @basic_rt_value_from_string(ptr)
declare ptr @basic_rt_value_from_boolean(i1)
declare ptr @basic_rt_value_from_composite(ptr)
declare ptr @basic_rt_value_from_array(ptr)
declare ptr @basic_rt_value_from_dictionary(ptr)
declare ptr @basic_rt_value_from_closure(ptr)
declare double @basic_rt_value_number(ptr, ptr)
declare ptr @basic_rt_value_string(ptr, ptr)
declare i1 @basic_rt_value_boolean(ptr, ptr)
declare ptr @basic_rt_value_composite(ptr, i64, ptr)
declare ptr @basic_rt_value_dictionary(ptr, ptr)
declare ptr @basic_rt_value_closure(ptr, ptr)
declare i1 @basic_rt_value_truthy(ptr)
declare i1 @basic_rt_value_equal(ptr, ptr)
declare ptr @basic_rt_value_add(ptr, ptr)
declare double @basic_rt_value_len(ptr)
declare ptr @basic_rt_value_index(ptr, i64, ptr, ptr)
declare void @basic_rt_value_set_index(ptr, i64, ptr, ptr, ptr)
declare ptr @basic_rt_value_field(ptr, ptr, ptr)
declare void @basic_rt_print_value(ptr)
declare ptr @basic_rt_value_text(ptr)
declare ptr @basic_rt_json_encode(ptr, i1)
declare ptr @basic_rt_json_decode(ptr, i1)
declare ptr @basic_rt_dictionary_new()
declare ptr @basic_rt_dictionary_copy(ptr)
declare void @basic_rt_dictionary_release(ptr)
declare ptr @basic_rt_dictionary_get(ptr, ptr, ptr)
declare void @basic_rt_dictionary_set(ptr, ptr, ptr, ptr)
declare void @basic_rt_print_dictionary(ptr)
declare ptr @basic_rt_dictionary_text(ptr)
declare ptr @basic_rt_composite_new(i64)
declare ptr @basic_rt_composite_copy(ptr)
declare void @basic_rt_composite_assign(ptr, ptr)
declare void @basic_rt_composite_release(ptr)
declare i64 @basic_rt_composite_type(ptr)
declare double @basic_rt_composite_get_number(ptr, i64)
declare void @basic_rt_composite_set_number(ptr, i64, double)
declare ptr @basic_rt_composite_get_string(ptr, i64)
declare void @basic_rt_composite_set_string(ptr, i64, ptr)
declare ptr @basic_rt_composite_get_composite(ptr, i64)
declare void @basic_rt_composite_set_composite(ptr, i64, ptr)
declare void @basic_rt_print_composite(ptr)
declare ptr @basic_rt_composite_text(ptr)
declare ptr @basic_rt_closure_new(ptr, ptr)
declare void @basic_rt_closure_retain(ptr)
declare void @basic_rt_closure_release(ptr)
declare ptr @basic_rt_closure_function(ptr)
declare ptr @basic_rt_closure_environment(ptr)
declare void @basic_rt_array_release(ptr)
declare i64 @basic_rt_array_offset(ptr, ptr, i64, ptr)
declare double @basic_rt_array_load_number(ptr, i64)
declare void @basic_rt_array_store_number(ptr, i64, double)
declare ptr @basic_rt_array_load_string(ptr, i64)
declare void @basic_rt_array_store_string(ptr, i64, ptr)
declare void @basic_rt_data_register(i64, ptr, ptr, ptr)
declare void @basic_rt_restore()
declare double @basic_rt_read_number(ptr)
declare ptr @basic_rt_read_string(ptr)
declare i32 @setjmp(ptr) returns_twice
declare void @basic_rt_error_install(ptr)
declare void @basic_rt_statement(i64, i64)
declare void @basic_rt_on_error(i64)
declare void @basic_rt_raise(double)
declare i64 @basic_rt_error_handler()
declare i64 @basic_rt_resume_next()
declare double @basic_rt_err()
declare double @basic_rt_erl()
declare void @basic_rt_cls()
declare void @basic_rt_capture_begin()
declare ptr @basic_rt_capture_end()
declare void @basic_rt_file_open(ptr, i64, double)
declare void @basic_rt_file_close(double)
declare void @basic_rt_file_print(double, ptr)
declare void @basic_rt_file_write_line(double, ptr)
declare void @basic_rt_file_input_begin(double)
declare double @basic_rt_file_input_number(double, ptr)
declare ptr @basic_rt_file_input_string(double)
declare ptr @basic_rt_file_line_input(double)
declare i1 @basic_rt_file_eof(double)
declare double @basic_rt_file_lof(double)
declare double @basic_rt_file_loc(double)
declare double @basic_rt_file_exists_number(ptr)
declare ptr @basic_rt_date()
declare ptr @basic_rt_time()
declare double @basic_rt_sleep(double)
declare ptr @basic_rt_input_chars(double)
declare ptr @basic_rt_file_cwd()
declare void @basic_rt_file_chdir(ptr)
declare void @basic_rt_file_mkdir(ptr)
declare void @basic_rt_file_rm(ptr)
declare void @basic_rt_file_rename(ptr, ptr)
declare i1 @basic_rt_file_exists(ptr)
declare i1 @basic_rt_file_isdir(ptr)
declare ptr @basic_rt_file_read_text(ptr)
declare void @basic_rt_file_write_text(ptr, ptr)
declare double @llvm.fabs.f64(double)
declare double @llvm.floor.f64(double)
declare double @llvm.trunc.f64(double)
declare double @llvm.round.f64(double)
declare double @llvm.sqrt.f64(double)
declare double @llvm.sin.f64(double)
declare double @llvm.cos.f64(double)
declare double @llvm.exp.f64(double)
declare double @llvm.log.f64(double)
declare double @tan(double)
declare double @atan(double)

@"G.V" = global ptr null

@data.kinds = private constant [1 x i8] [i8 0]
@data.numbers = private constant [1 x double] [double 0.0]
@data.strings = private constant [1 x ptr] [ptr null]
@.str.1 = private unnamed_addr constant [2 x i8] c"V\00"
@.str.2 = private unnamed_addr constant [13 x i8] c"[10, 20, 30]\00"
@.str.3 = private unnamed_addr constant [2 x i8] c"V\00"
@.str.4 = private unnamed_addr constant [13 x i8] c"not an array\00"
@.str.5 = private unnamed_addr constant [2 x i8] c"V\00"
@.str.6 = private unnamed_addr constant [19 x i8] c"not reached either\00"
@.str.7 = private unnamed_addr constant [4 x i8] c"ERR\00"

define i32 @main(i32 %argc, ptr %argv) {
"prologue":
  %"scratch.indexes" = alloca [1 x double]
  %"scratch.values" = alloca [8 x ptr]
  call void @basic_rt_start()
  call void @basic_rt_data_register(i64 0, ptr @data.kinds, ptr @data.numbers, ptr @data.strings)
  %"error.jmpbuf" = alloca [64 x i64]
  call void @basic_rt_error_install(ptr %"error.jmpbuf")
  %"error.landed" = call i32 @setjmp(ptr %"error.jmpbuf")
  %"error.flag" = icmp ne i32 %"error.landed", 0
  br i1 %"error.flag", label %"error.dispatch", label %"b.entry"
"b.entry":
  br label %"b.s0"
"b.s0":
  call void @basic_rt_statement(i64 0, i64 1)
  %t1 = call ptr @basic_rt_value_empty()
  %t2 = load ptr, ptr @"G.V"
  %t3 = call ptr @basic_rt_value_store(ptr %t2, ptr %t1, ptr @.str.1)
  call void @basic_rt_value_release(ptr %t2)
  store ptr %t3, ptr @"G.V"
  call void @basic_rt_value_release(ptr %t1)
  br label %"b.s1"
"b.s1":
  call void @basic_rt_statement(i64 1, i64 2)
  %t4 = call ptr @basic_rt_string_literal(ptr @.str.2, i64 12)
  %t5 = call ptr @basic_rt_json_decode(ptr %t4, i1 true)
  %t6 = load ptr, ptr @"G.V"
  %t7 = call ptr @basic_rt_value_store(ptr %t6, ptr %t5, ptr @.str.3)
  call void @basic_rt_value_release(ptr %t6)
  store ptr %t7, ptr @"G.V"
  call void @basic_rt_string_release(ptr %t4)
  call void @basic_rt_value_release(ptr %t5)
  br label %"b.s2"
"b.s2":
  call void @basic_rt_statement(i64 2, i64 3)
  %t8 = load ptr, ptr @"G.V"
  %t9 = call double @basic_rt_value_len(ptr %t8)
  call void @basic_rt_print_number(double %t9)
  call void @basic_rt_print_newline()
  br label %"b.s3"
"b.s3":
  call void @basic_rt_statement(i64 3, i64 4)
  call void @basic_rt_on_error(i64 0)
  br label %"b.s4"
"b.s4":
  call void @basic_rt_statement(i64 4, i64 5)
  %t10 = call ptr @basic_rt_string_literal(ptr @.str.4, i64 12)
  %t11 = call ptr @basic_rt_value_from_string(ptr %t10)
  %t12 = load ptr, ptr @"G.V"
  %t13 = call ptr @basic_rt_value_store(ptr %t12, ptr %t11, ptr @.str.5)
  call void @basic_rt_value_release(ptr %t12)
  store ptr %t13, ptr @"G.V"
  call void @basic_rt_string_release(ptr %t10)
  call void @basic_rt_value_release(ptr %t11)
  br label %"b.s5"
"b.s5":
  call void @basic_rt_statement(i64 5, i64 6)
  %t14 = call ptr @basic_rt_string_literal(ptr @.str.6, i64 18)
  call void @basic_rt_print_text(ptr %t14)
  call void @basic_rt_print_newline()
  call void @basic_rt_string_release(ptr %t14)
  br label %"b.s6"
"b.s6":
  call void @basic_rt_statement(i64 6, i64 7)
  br label %"b.s7"
"b.s7":
  call void @basic_rt_statement(i64 7, i64 8)
  %t15 = call ptr @basic_rt_string_literal(ptr @.str.7, i64 3)
  call void @basic_rt_print_text(ptr %t15)
  %t16 = call double @basic_rt_err()
  call void @basic_rt_print_number(double %t16)
  call void @basic_rt_print_newline()
  call void @basic_rt_string_release(ptr %t15)
  br label %"b.s8"
"b.s8":
  call void @basic_rt_statement(i64 8, i64 9)
  call void @basic_rt_finish()
  ret i32 0
"b.program.end":
  call void @basic_rt_finish()
  ret i32 0
"error.dispatch":
  %t17 = call i64 @basic_rt_error_handler()
  switch i64 %t17, label %"error.bad" [ i64 0, label %"b.s6" ]
"error.bad":
  unreachable
"resume.dispatch":
  %t18 = call i64 @basic_rt_resume_next()
  switch i64 %t18, label %"resume.bad" [ i64 0, label %"b.s1" i64 1, label %"b.s2" i64 2, label %"b.s3" i64 3, label %"b.s4" i64 4, label %"b.s5" i64 5, label %"b.s6" i64 6, label %"b.s7" i64 7, label %"b.s8" i64 8, label %"b.program.end" ]
"resume.bad":
  unreachable
}