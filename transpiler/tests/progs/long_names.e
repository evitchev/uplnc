/* Identifiers may be up to 63 characters (they were limited to 15). Names
   that agree in their first 15, or even 62, characters are distinct, and the
   long limit holds for every kind of name: locals, parameters, globals,
   functions, macros, enum constants, struct types, fields, and methods, whose
   `Struct.method` mangle may use all 63. Returns the number of the first
   failing check. -> 42 */
#define macro_name_well_past_the_old_fifteen_character_limit 5
enum { enum_constant_whose_name_runs_long = 7 };
var int:global_counter_with_a_descriptive_name;
struct rectangle_with_a_long_type_name
{
  int width_of_the_rectangle_in_cells;
  int height_of_the_rectangle_in_cells;
  func area_of_this_rectangle_in_cells;
};
method rectangle_with_a_long_type_name.area_of_this_rectangle_in_cells()
{
  return width_of_the_rectangle_in_cells*height_of_the_rectangle_in_cells;
}
func add_to_the_global_counter_and_return_it(amount_to_add_to_counter:int)
{
  global_counter_with_a_descriptive_name=
  global_counter_with_a_descriptive_name+amount_to_add_to_counter;
  return global_counter_with_a_descriptive_name;
}
func main()
{
  var int:a_local_whose_name_is_exactly_sixty_three_characters_long_xyz_a;
  var int:a_local_whose_name_is_exactly_sixty_three_characters_long_xyz_b;
  var int:counter_of_apples,counter_of_applesauce;
  var rectangle_with_a_long_type_name:rect;
  a_local_whose_name_is_exactly_sixty_three_characters_long_xyz_a=1;
  a_local_whose_name_is_exactly_sixty_three_characters_long_xyz_b=2;
  if(a_local_whose_name_is_exactly_sixty_three_characters_long_xyz_a!=1)
  return 1;   /* names differing only in the 63rd character are distinct */
  counter_of_apples=3;
  counter_of_applesauce=4;
  if(counter_of_apples+counter_of_applesauce!=7)return 2;   /* >15 shared */
  if(macro_name_well_past_the_old_fifteen_character_limit!=5)return 3;
  if(enum_constant_whose_name_runs_long!=7)return 4;
  global_counter_with_a_descriptive_name=10;
  if(add_to_the_global_counter_and_return_it(6)!=16)return 5;
  rect.width_of_the_rectangle_in_cells=4;
  rect.height_of_the_rectangle_in_cells=6;
  if(rect.area_of_this_rectangle_in_cells()!=24)return 6;
  if(a_local_whose_name_is_exactly_sixty_three_characters_long_xyz_b!=2)
  return 7;
  return 42;
}
