defmodule Honey.TranslatorContext do
  defstruct [:maps]

  def new(maps) do
    %__MODULE__{maps: maps}
  end
end

defmodule Honey.Translator do
  alias Honey.{Boilerplates, TranslatedCode, AvailableProgramTypes, TranslatorContext}

  import Honey.Utils, only: [gen: 1, var_to_string: 1]

  def unique_helper_var() do
    "helper_var_#{:erlang.unique_integer([:positive])}"
  end

  def to_c(tree, context \\ {})

  # Variables
  def to_c({var, var_meta, var_context}, _context) when is_atom(var) and is_atom(var_context) do
    c_var_name = var_to_string({var, var_meta, var_context})
    TranslatedCode.new("", c_var_name)
  end

  # Blocks
  def to_c({:__block__, _, [expr]}, context) do
    to_c(expr, context)
  end

  def to_c({:__block__, _, _} = ast, context) do
    block = block_to_c(ast, context)
    %TranslatedCode{block | code: "\n" <> block.code <> "\n"}
  end

  # Erlang functions
  def to_c({{:., _, [:erlang, function]}, _, [lhs, rhs]}, _context) do
    func_string =
      case function do
        :+ ->
          "Sum"

        :- ->
          "Subtract"

        :* ->
          "Multiply"

        :/ ->
          "Divide"

        :== ->
          "Equals"

        # :> ->
        #   " ..."

        # :>= ->
        #   " ... "

        # :< ->
        #   " ..."

        # :<= ->
        #   " ... "

        # :bsr ->
        #   " ... "

        # :bsl ->
        #   " ... "

        _ ->
          raise "Erlang function not supported: #{Atom.to_string(function)}"
      end

    lhs_in_c = to_c(lhs)
    rhs_in_c = to_c(rhs)
    c_var_name = unique_helper_var()

    """
    #{lhs_in_c.code}
    #{rhs_in_c.code}
    BINARY_OPERATION(#{c_var_name}, #{func_string}, #{lhs_in_c.return_var_name}, #{rhs_in_c.return_var_name})
    """
    |> gen()
    |> TranslatedCode.new(c_var_name)
  end

  # XdpMd
  def to_c({{:., _, [Honey.XdpMd, function]}, _, params}, _context) do
    case function do
      :convert_to_ethhdr! ->
        [pos] = params

        if !is_integer(pos) do
          raise "convert_to_ethhdr!: 'pos' must be an integer. Received: #{Macro.to_string(pos)}"
        end

        data_var = unique_helper_var()
        data_end_var = unique_helper_var()
        eth_c_var = unique_helper_var()
        eth_generic_var = unique_helper_var()
        off_var = unique_helper_var()

        """
        void *#{data_end_var} = (void *)(long)arg_1->data_end;
        void *#{data_var} = (void *)(long)arg_1->data;
        __u32 #{off_var} = sizeof(struct ethhdr) + #{pos};
        struct ethhdr *#{eth_c_var} = #{data_var} + #{pos};
        if(#{data_var} + #{off_var} > #{data_end_var}) {
          op_result = (OpResult){.exception = 1, .exception_msg = "(ConvertionError) Can't obtain ethhdr from position #{pos} because there is not enough data."};
          goto CATCH;
        }
        Generic #{eth_generic_var} = (Generic){.type = TYPE_Ethhdr, .value.value_Ethhdr = {(*heap_index)++, (*heap_index)++, (*heap_index)++}};
        if (#{eth_generic_var}.value.value_Ethhdr.idx_h_dest < HEAP_SIZE)
        {
          (*heap)[#{eth_generic_var}.value.value_Ethhdr.idx_h_dest] = (Generic){.type = STRING, .value.string = {.start = *string_pool_index, .end = *string_pool_index + ETH_ALEN - 1}};

          for(unsigned i  = 0; i < ETH_ALEN; i++, (*string_pool_index)++) {
            if(*string_pool_index >= STRING_POOL_SIZE) {
              op_result.exception = 1;
              __builtin_memcpy(op_result.exception_msg, "(MemoryLimitReached) Impossible to create string, the string pool is full.", sizeof("(MemoryLimitReached)1 Impossible to create string, the string pool is full."));
              goto CATCH;
            }
            (*string_pool)[*string_pool_index] = #{eth_c_var}->h_dest[i];
          }
        }
        if (#{eth_generic_var}.value.value_Ethhdr.idx_h_source < HEAP_SIZE)
        {
          (*heap)[#{eth_generic_var}.value.value_Ethhdr.idx_h_source] = (Generic){.type = STRING, .value.string = {.start = *string_pool_index, .end = *string_pool_index + ETH_ALEN - 1}};

          for(unsigned i  = 0; i < ETH_ALEN; i++, (*string_pool_index)++) {
            if(*string_pool_index >= STRING_POOL_SIZE) {
              op_result.exception = 1;
              __builtin_memcpy(op_result.exception_msg, "(MemoryLimitReached) Impossible to create string, the string pool is full.", sizeof("(MemoryLimitReached)1 Impossible to create string, the string pool is full."));
              goto CATCH;
            }
            (*string_pool)[*string_pool_index] = #{eth_c_var}->h_source[i];
          }
        }
        if (#{eth_generic_var}.value.value_Ethhdr.idx_h_proto < HEAP_SIZE)
        {
          (*heap)[#{eth_generic_var}.value.value_Ethhdr.idx_h_proto] = (Generic){.type = INTEGER, .value.integer = #{eth_c_var}->h_proto};
        }
        """
        |> gen()
        |> TranslatedCode.new(eth_generic_var)
    end
  end

  def to_c(ast = {{:., _, [Honey.Bpf.BpfHelpers, _]}, _, _}, context) do
    matching_bpf_helpers({}, ast, context)
  end

  # General dot operator
  def to_c(ast = {{:., _, [var, property]}, _, _}, _context) do
    var_name_in_c = var_to_string(var)
    property_var = unique_helper_var()
    property_id_var = unique_helper_var()

    property_id = "field_id_#{property}"

    """
    Generic #{property_var} = {0};
    #ifdef #{property_id}
    unsigned #{property_id_var} = #{property_id};
    getMember(&op_result, &#{var_name_in_c}, #{property_id_var}, &#{property_var});
    if (op_result.exception) goto CATCH;
    #else
    op_result = (OpResult){ .exception = 1, .exception_msg = \"(InvalidField) Tried to access invalid field '#{property}' of variable '#{elem(var, 0)}'.\"};
    goto CATCH;
    #endif
    """
    |> gen()
    |> TranslatedCode.new(property_var)
  end

  # function raise/1
  def to_c({:raise, _meta, [msg]}, _context) when is_bitstring(msg) do
    new_var_name = unique_helper_var()

    """
    Generic #{new_var_name} = (Generic){0};
    op_result = (OpResult){ .exception = 1, .exception_msg = \"(RaiseException) #{msg}\"};
    goto CATCH;
    """
    |> gen()
    |> TranslatedCode.new(new_var_name)
  end

  # Match operator, not complete
  def to_c({:=, _, [lhs, rhs]}, context) do
    case rhs do
      {{:., _, [Honey.Bpf.BpfHelpers, _]}, _, _} ->
        matching_bpf_helpers(lhs, rhs, context)

      _ ->
        rhs_in_c = to_c(rhs)
        c_var_name = var_to_string(lhs)

        """
        #{rhs_in_c.code}
        Generic #{c_var_name} = #{rhs_in_c.return_var_name};
        """
        |> gen()
        |> TranslatedCode.new(c_var_name)
    end
  end

  # Cond
  def to_c({:cond, _, [[do: conds]]}, _context) do
    cond_var = unique_helper_var()

    cond_code = cond_statments_to_c(conds, cond_var)

    """
    Generic #{cond_var} = {.type = INTEGER, .value.integer = 0};
    #{cond_code}
    """
    |> gen()
    |> TranslatedCode.new(cond_var)
  end

  # Other structures
  def to_c(other, _context) do
    case constant_to_code(other) do
      {:ok, code} ->
        code

      _ ->
        IO.puts("We cannot convert this structure yet:")
        IO.inspect(other)
        raise "We cannot convert this structure yet."
    end
  end

  def constant_to_code(item) do
    var_name_in_c = unique_helper_var()

    cond do
      is_integer(item) ->
        {:ok,
         TranslatedCode.new(
           "Generic #{var_name_in_c} = {.type = INTEGER, .value.integer = #{item}};",
           var_name_in_c
         )}

      is_number(item) ->
        {:ok,
         TranslatedCode.new(
           "Generic #{var_name_in_c} = {.type = DOUBLE, .value.double_precision = #{item}};",
           var_name_in_c
         )}

      # Considering only strings for now
      is_bitstring(item) ->
        # TODO: Check whether the zero-termination is ok the way it is

        # TODO: consider other special chars
        # You can use `Macro.unescape_string/2` for this, but please check it
        str = String.replace(item, "\n", "\\n")
        str_len = String.length(str) + 1
        new_var_name = unique_helper_var()
        end_var_name = "end_#{new_var_name}"
        len_var_name = "len_#{new_var_name}"

        code =
          gen("""
          unsigned #{len_var_name} = #{str_len};
          unsigned #{end_var_name} = *string_pool_index + #{len_var_name} - 1;
          if(#{end_var_name} + 1 >= STRING_POOL_SIZE) {
            op_result = (OpResult){.exception = 1, .exception_msg = "(MemoryLimitReached) Impossible to create string, the string pool is full."};
            goto CATCH;
          }

          if(*string_pool_index < STRING_POOL_SIZE - #{len_var_name}) {
            __builtin_memcpy(&(*string_pool)[*string_pool_index], "#{str}", #{len_var_name});
          }

          Generic #{var_name_in_c} = {.type = STRING, .value.string = (String){.start = *string_pool_index, .end = #{end_var_name}}};
          *string_pool_index = #{end_var_name} + 1;
          """)

        {:ok, TranslatedCode.new(code, var_name_in_c)}

      is_atom(item) ->
        # TODO: Convert arbitrary atoms
        value =
          case item do
            true ->
              "ATOM_TRUE"

            false ->
              "ATOM_FALSE"

            nil ->
              "ATOM_NIL"

            _ ->
              raise "We cannot convert arbitrary atoms yet (only 'true', 'false' and 'nil')."
          end

        code = "Generic #{var_name_in_c} = #{value};"
        {:ok, TranslatedCode.new(code, var_name_in_c)}

      is_binary(item) ->
        raise "We cannot convert binary yet."

      # TODO: create an option for tuples and arrays

      true ->
        :error
    end
  end

  def cond_statments_to_c([], cond_var_name_in_c) do
    "#{cond_var_name_in_c} = (Generic){.type = ATOM, .value.string = (String){0, 2}};"
  end

  def cond_statments_to_c([cond_stat | other_conds], cond_var_name_in_c) do
    {:->, _, [[condition] | [block]]} = cond_stat
    condition_in_c = to_c(condition)

    block_in_c = to_c(block)

    gen("""
    #{condition_in_c.code}
    if (to_bool(&#{condition_in_c.return_var_name})) {
      #{block_in_c.code}
      #{cond_var_name_in_c} = #{block_in_c.return_var_name};
    } else {
      #{cond_statments_to_c(other_conds, cond_var_name_in_c)}
    }
    """)
  end

  def matching_bpf_helpers(lhs, {{:., _, [Honey.Bpf.BpfHelpers, function]}, _, params}, context) do
    case function do
      :bpf_printk ->
        [[string | other_params]] = params

        if !is_bitstring(string) do
          raise "First argument of bpf_printk must be a string. Received: #{Macro.to_string(params)}"
        end

        string = String.replace(string, "\n", "\\n")
        code_vars = Enum.map(other_params, &to_c(&1, context))

        code = Enum.reduce(code_vars, "", fn %{code: code}, so_far -> so_far <> code end)

        vars =
          Enum.reduce(code_vars, "", fn translated, so_far ->
            so_far = if so_far != "", do: so_far <> ", ", else: ""
            so_far <> translated.return_var_name <> ".value.integer"
          end)

        result_var = unique_helper_var()

        # TODO: Instead of returning 0, return the actual result of the call to bpf_printk
        """
        #{code}
        bpf_printk(\"#{string}\", #{vars});
        Generic #{result_var} = {.type = INTEGER, .value.integer = 0};
        """
        |> gen()
        |> TranslatedCode.new(result_var)

      # TODO: Maps stopped working after the addition of dynamic types.
      :bpf_map_lookup_elem ->
        [map_name, key_ast] = params

        if !is_atom(map_name) do
          raise "bpf_map_lookup_elem: 'map' must be an atom. Received: #{Macro.to_string(map_name)}"
        end

        declared_maps = context.maps

        map =
          Enum.find(declared_maps, nil, fn map ->
            map[:name] == map_name
          end)

        if(!map) do
          raise "bpf_map_update_elem: No map declared with name #{map_name}."
        end

        map_content = map[:content]

        case lhs do
          {found_var, item_var} ->
            found_var_name = var_to_string(found_var)
            item_var_name = var_to_string(item_var)

            str_map_name = Atom.to_string(map_name)

            key = to_c(key_ast, context)

            result_var_pointer = unique_helper_var()
            result_var = unique_helper_var()

            if(
              map_content.type == BPF_MAP_TYPE_PERCPU_ARRAY or
                map_content.type == BPF_MAP_TYPE_ARRAY
            ) do
              """
              #{key.code}
              if(#{key.return_var_name}.type != INTEGER) {
                op_result = (OpResult){.exception = 1, .exception_msg = "(MapKey) Key passed to bpf_map_lookup_elem is not integer."};
                goto CATCH;
              }
              Generic *#{result_var_pointer} = bpf_map_lookup_elem(&#{str_map_name}, &(#{key.return_var_name}.value.integer));

              Generic #{result_var} = (Generic){.type = INTEGER, .value.integer = 0}; // This is a fake variable, necessary while we still need to return a var name.

              Generic #{found_var_name} = (Generic){.type = INTEGER, .value.integer = #{result_var_pointer} != NULL};
              Generic #{item_var_name} = (Generic){0};
              if(!#{result_var_pointer}) {
                #{item_var_name} = ATOM_NIL;
              } else {
                #{item_var_name} = *#{result_var_pointer};
              }
              """
              |> gen()
              |> TranslatedCode.new(result_var)
            else
              case Map.fetch(map_content, :key_type) do
                {:ok, key_type} ->
                  case key_type[:type] do
                    :string ->
                      """
                      #{key.code}
                      if(#{key.return_var_name}.type != STRING) {
                        op_result = (OpResult){.exception = 1, .exception_msg = "(MapKey) Key passed to bpf_map_lookup_elem is not a string."};
                        goto CATCH;
                      }
                      if(#{key.return_var_name}.value.string.end - #{key.return_var_name}.value.string.start + 1 < #{key_type[:size]}) {
                        op_result = (OpResult){.exception = 1, .exception_msg = "(MapKey) String passed to bpf_map_lookup_elem is not long enough for key of size #{key_type[:size]}."};
                        goto CATCH;
                      }
                      if(#{key.return_var_name}.value.string.start >= STRING_POOL_SIZE - #{key_type[:size]}) {
                        op_result = (OpResult){.exception = 1, .exception_msg = "(UnexpectedBehavior) something wrong happened inside the Elixir runtime for eBPF. (function bpf_map_lookup_elem)."};
                        goto CATCH;
                      }
                      Generic *#{result_var_pointer} = bpf_map_lookup_elem(&#{str_map_name}, (*string_pool) + #{key.return_var_name}.value.string.start);

                      Generic #{result_var} = (Generic){.type = INTEGER, .value.integer = 0}; // This is a fake variable, necessary while we still need to return a var name.

                      Generic #{found_var_name} = (Generic){0};
                      Generic #{item_var_name} = (Generic){0};
                      if(!#{result_var_pointer}) {
                        #{found_var_name} = ATOM_FALSE;
                        #{item_var_name} = ATOM_NIL;
                      } else {
                        #{found_var_name} = ATOM_TRUE;
                        #{item_var_name} = *#{result_var_pointer};
                      }
                      """
                      |> gen()
                      |> TranslatedCode.new(result_var)
                  end
              end
            end

          _ ->
            raise "In the alpha version of Honey Elixir, use pattern matching when calling bpf_map_lookup_elem: \n    {found, item} = bpf_map_lookup_elem(...)"
        end

      :bpf_map_update_elem ->
        [map_name, key_ast, value_ast | _] = params

        declared_maps = context.maps

        if !is_atom(map_name) do
          raise "bpf_map_update_elem: 'map' must be an atom. Received: #{Macro.to_string(map_name)}"
        end

        str_map_name = Atom.to_string(map_name)

        map =
          Enum.find(declared_maps, nil, fn map ->
            map[:name] == map_name
          end)

        if(!map) do
          raise "bpf_map_update_elem: No map declared with name #{map_name}."
        end

        key = to_c(key_ast, context)
        value = to_c(value_ast, context)

        result_var_c = unique_helper_var()
        result_var = unique_helper_var()

        map_content = map[:content]

        if(
          map_content.type == BPF_MAP_TYPE_PERCPU_ARRAY or map_content.type == BPF_MAP_TYPE_ARRAY
        ) do
          """
          #{key.code}
          #{value.code}
          if(#{key.return_var_name}.type != INTEGER) {
            op_result = (OpResult){.exception = 1, .exception_msg = "(MapKey) Keys passed to bpf_map_update_elem is not integer."};
            goto CATCH;
          }
          int #{result_var_c} = bpf_map_update_elem(&#{str_map_name}, &(#{key.return_var_name}.value.integer), &#{value.return_var_name}, BPF_ANY);
          Generic #{result_var} = (Generic){.type = INTEGER, .value.integer = #{result_var_c}};
          """
          |> gen()
          |> TranslatedCode.new(result_var)
        else
          case Map.fetch(map_content, :key_type) do
            {:ok, key_type} ->
              case key_type[:type] do
                :string ->
                  """
                  #{key.code}
                  if(#{key.return_var_name}.type != STRING) {
                    op_result = (OpResult){.exception = 1, .exception_msg = "(MapKey) Key passed to bpf_map_lookup_elem is not a string."};
                    goto CATCH;
                  }
                  if(#{key.return_var_name}.value.string.end - #{key.return_var_name}.value.string.start + 1 < #{key_type[:size]}) {
                    op_result = (OpResult){.exception = 1, .exception_msg = "(MapKey) String passed to bpf_map_lookup_elem is not long enough for key of size #{key_type[:size]}."};
                    goto CATCH;
                  }
                  if(#{key.return_var_name}.value.string.start >= STRING_POOL_SIZE - #{key_type[:size]}) {
                    op_result = (OpResult){.exception = 1, .exception_msg = "(UnexpectedBehavior) something wrong happened inside the Elixir runtime for eBPF. (function bpf_map_lookup_elem)."};
                    goto CATCH;
                  }
                  int #{result_var_c} = bpf_map_update_elem(&#{str_map_name}, (*string_pool) + #{key.return_var_name}.value.string.start, &#{value.return_var_name}, BPF_ANY); // TODO: Allow other flags

                  Generic #{result_var} = (Generic){.type = INTEGER, .value.integer = #{result_var_c}};
                  """
                  |> TranslatedCode.new(result_var)
              end

            _ ->
              raise "Missing attribute 'key_type' on map #{map_name}. Maps of type different than BPF_MAP_TYPE_PERCPU_ARRAY and BPF_MAP_TYPE_ARRAY must contain the attribute 'key_type'."
          end
        end

      :bpf_get_current_pid_tgid ->
        result_var = unique_helper_var()

        "Generic #{result_var} = {.type = INTEGER, .value.integer = bpf_get_current_pid_tgid()};\n"
        |> gen()
        |> TranslatedCode.new(result_var)
    end
  end

  defp block_to_c({:__block__, _, exprs}, context) do
    Enum.reduce(exprs, Honey.TranslatedCode.new(), fn expr, translated_so_far ->
      translated_expr = to_c(expr, context)

      %TranslatedCode{
        translated_expr
        | code: translated_so_far.code <> "\n" <> translated_expr.code
      }
    end)
  end

  defp ensure_right_type(type) do
    # TODO: Also check if the number of arguments received in main is correct

    available_types = AvailableProgramTypes.generate_available_types()

    case type do
      type when is_map_key(available_types, type) ->
        available_types[type]

      type when type in ["", nil] ->
        raise "The main/1 function must be preceded by a @sec indicating the type of the program."

      type ->
        raise "We cannot convert this Program Type yet: #{type}"
    end
  end

  def translate(func_name, func_args, ast, sec, license, requires, elixir_maps) do
    case func_name do
      "main" ->
        program_type = ensure_right_type(sec)
        func_args_str = Enum.map(func_args, &var_to_string/1)

        context = TranslatorContext.new(elixir_maps)
        translated_code = to_c(ast, context)

        program_type
        |> Boilerplates.Config.new(func_args_str, license, elixir_maps, requires, translated_code)
        |> Boilerplates.generate_whole_code()

      _ ->
        false
    end
  end
end
