defmodule Honey.Translator do
  alias Honey.Boilerplates
  alias Honey.TranslatedCode

  import Honey.Utils, only: [gen: 1, var_to_string: 1, is_var: 1]

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

  # C libraries
  def to_c({{:., _, [Honey.Bpf.Bpf_helpers, function]}, _, params}, context) do
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
        [map, key_ast] = params

        if !is_atom(map) do
          raise "bpf_map_lookup_elem: 'map' must be an atom. Received: #{Macro.to_string(map)}"
        end

        str_map_name = Atom.to_string(map)

        key = to_c(key_ast, context)

        result_var_pointer = unique_helper_var()
        result_var = unique_helper_var()

        """
        #{key.code}
        if(#{key.return_var_name}.type != INTEGER) {
          op_result = (OpResult){.exception = 1, .exception_msg = "(MapKey) Keys passed to bpf_map_lookup_elem is not integer."};
          goto CATCH;
        }
        Generic *#{result_var_pointer} = bpf_map_lookup_elem(&#{str_map_name}, &(#{key.return_var_name}.value.integer));
        if(!#{result_var_pointer}) {
          op_result = (OpResult){.exception = 1, .exception_msg = "(MapAcess) Impossible to access map '#{str_map_name}' with the key informed."};
          goto CATCH;
        }
        Generic #{result_var} = *#{result_var_pointer};
        """
        |> gen()
        |> TranslatedCode.new(result_var)

      :bpf_map_update_elem ->
        [map, key_ast, value_ast] = params

        if !is_atom(map) do
          raise "bpf_map_update_elem: 'map' must be an atom. Received: #{Macro.to_string(map)}"
        end

        str_map_name = Atom.to_string(map)

        # if(!is_atom(flags)) do
        #   throw "bpf_map_update_elem: 'flags' must be an atom. Received: #{Macro.to_string(map)}"
        # end
        # flags_map_name = Atom.to_string(flags)
        # |> String.replace("Elixir.", "")

        key = to_c(key_ast, context)
        value = to_c(value_ast, context)

        result_var_c = unique_helper_var()
        result_var = unique_helper_var()

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

      :bpf_get_current_pid_tgid ->
        result_var = unique_helper_var()

        "Generic #{result_var} = {.type = INTEGER, .value.integer = bpf_get_current_pid_tgid()};\n"
        |> gen()
        |> TranslatedCode.new(result_var)
    end
  end

  # General dot operator
  def to_c({{:., _, [var, property]}, _, _}, _context) do
    var_name_in_c = var_to_string(var)
    property_var = unique_helper_var()
    str_name_var = unique_helper_var()

    """
    Generic #{property_var} = {0};
    char #{str_name_var}[20] = "#{Atom.to_string(property)}";
    getMember(&op_result, &#{var_name_in_c}, #{str_name_var}, &#{property_var});
    if (op_result.exception) goto CATCH
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
  def to_c({:=, _, [lhs, rhs]}, _context) do
    IO.puts("==============")
    IO.inspect(lhs)
    IO.inspect(rhs)
    IO.puts("==============")


    rhs_in_c = to_c(rhs)
    # c_var_name = var_to_string(lhs)

    "#{rhs_in_c.code}\n" <> pattern_matching(lhs, rhs_in_c.return_var_name)
    |> gen()
    |> TranslatedCode.new(rhs_in_c.return_var_name)
    # """
    # #{rhs_in_c.code}
    # Generic #{c_var_name} = #{rhs_in_c.return_var_name};
    # """
    # |> gen()
    # |> TranslatedCode.new(c_var_name)
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

  # def pattern_matching({first, second} = var, helper_var_name) do
  #   pattern_matching(first, helper_var_name <> "")
  #     <>
  #   pattern_matching(second, helper_var_name)
  # end

  def pattern_matching(var, helper_var_name) when is_var(var) do
    c_var_name = var_to_string(var)
    """
    Generic #{c_var_name} = #{helper_var_name};
    """
  end

  def pattern_matching(constant, helper_var_name) do
    constant_code = to_c(constant)
    """
    if(values_are_equal(&#{constant_code.return_var_name}, &#{helper_var_name})) {
      op_result = (OpResult){.exception = 1, .exception_msg = "(MatchError) No match of right hand side value."};
      goto CATCH
    }
    """
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

  defp block_to_c({:__block__, _, exprs}, context) do
    Enum.reduce(exprs, Honey.TranslatedCode.new(), fn expr, translated_so_far ->
      translated_expr = to_c(expr, context)

      %TranslatedCode{
        translated_expr
        | code: translated_so_far.code <> "\n" <> translated_expr.code
      }
    end)
  end

  @supported_types ~w[tracepoint/syscalls/sys_enter_kill]
  defp ensure_right_type(type) do
    case type do
      type when type in @supported_types ->
        true

      type when type in ["", nil] ->
        raise "The main/1 function must be preceded by a @sec indicating the type of the program."

      type ->
        raise "We cannot convert this Program Type yet: #{type}"
    end
  end

  def translate(func_name, ast, sec, license, requires, elixir_maps) do
    case func_name do
      "main" ->
        ensure_right_type(sec)
        translated_code = to_c(ast)

        sec
        |> Boilerplates.config(["ctx0nil"], license, elixir_maps, requires, translated_code)
        |> Boilerplates.generate_whole_code()

      _ ->
        false
    end
  end
end
