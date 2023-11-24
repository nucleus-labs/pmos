#!/usr/bin/env bash

# ================================================================================================
#                                            GLOBALS

declare -A valid_flags
declare -A valid_flag_names

declare -a flag_schedule
declare -a flag_unschedule

declare -a arguments
arguments+=($*)

declare -a builtin_targets

valid_arg_types=("any" "int" "float" "string")

BUILTIN_DEPENDENCIES=("tput")
IGNORE_DEPENDENCIES=0
PRESERVE_FLAGS=0

# ================================================================================================
#                                              UTILS
ERR_INFO="\${BASH_SOURCE[0]} \${LINENO}"
# (1: file; 2: line number; 3: error message; 4: exit code)
function error () {
    local file="$1"
    local line_number="$2"
    local message="$3"
    local code="${4:-1}"
    [[ -n "$message" ]] && echo -e "[ERROR][${file}:${line_number}][${code}]: ${message}" || echo "[ERROR][${file}][${line_number}][${code}]"
    exit ${code}
}

# (1: array name (global); 2: array type (-a/-A))
function arr_max_value () {
    [[ -z "$1" ]]           && caller >&2 && error $(eval echo "${ERR_INFO}") "Array name is empty!" 80
    local arr_declare="$(declare -p "$1" 2>/dev/null)"
    [[ -z "${!1+x}" || "${arr_declare}" != "declare"* ]]                                            \
                            && caller >&2 && error $(eval echo "${ERR_INFO}") "Variable '$1' does not exist!" 81
    [[ ! -v "$1"    || "${arr_declare}" != "declare -a"* && "${arr_declare}" != "declare -A"* ]]    \
                            && caller >&2 && error $(eval echo "${ERR_INFO}") "Variable '$1' is not an array!" 82
    local -n arr="$1"
    local max_value=${arr[0]}

    for item in "${arr[@]}"; do
        [[ ! $2 =~ ^[0-9]+$ ]]  && caller >&2 && error $(eval echo "${ERR_INFO}") "value '$2' is not a valid number!" 83
        max_value=$(( ${item} > ${max_value} ? ${item} : ${max_value} ))
    done
    echo ${max_value}
}

# (1: array name (global); 2: index to pop; 3: array type (-a/-A))
function arr_pop () {
    [[ -z "$1" ]] && caller >&2 && error $(eval echo "${ERR_INFO}") "Array name is empty!" 90

    local arr_declare="$(declare -p "$1" 2>/dev/null)"

    [[ -z "${!1+x}" || "${arr_declare}" != "declare"* ]] && \
        caller >&2 && error $(eval echo "${ERR_INFO}") "Variable '$1' does not exist or is empty!" 91

    [[ ! -v "$1"    || "${arr_declare}" != "declare -a"* && "${arr_declare}" != "declare -A"* ]] && \
        caller >&2 && error $(eval echo "${ERR_INFO}") "Variable '$1' is not an array!" 92

    [[ ! $2 =~ ^[0-9]+$ ]]  && \
        caller >&2 && error $(eval echo "${ERR_INFO}") "Index '$2' is not a valid number!" 93

    [[ ! -v $1[$2] ]]       && \
        caller >&2 && error $(eval echo "${ERR_INFO}") "Array element at index $2 does not exist!" 94

    eval "$1=(\${$1[@]:0:$2} \${$1[@]:$2+1})"
}

# ================================================================================================
#                                       CORE FUNCTIONALITY
function validate_dependencies () {
    local all_deps=(${BUILTIN_DEPENDENCIES[@]} ${DEPENDENCIES[@]})
    local missing_deps=""

    for (( i=0; i<${#all_deps[@]}; i++ )); do
        which "${all_deps[i]}" &> /dev/null
        local _ret=$?
        [[ ${_ret} -ne 0 ]] && missing_deps+="\n    ${all_deps[i]}"
    done

    [[ ${#missing_deps} -gt 0 ]] \
        && error $(eval echo "${ERR_INFO}") "Please install missing dependencies:${missing_deps}" 255

}

#  1: flag (single character); 2: name; 3: description; 4: priority;
#  5: argument name; 6: argument type; 7: argument description
function add_flag () {
    local flag="$1"
    local name="$2"
    local description="$3"
    local priority="$4"
    local argument="$5"
    local argument_type="$6"
    local arg_description="$7"

    # basic validations
    [[ x"${flag}" == x"" ]]             && caller >&2 && error $(eval echo "${ERR_INFO}") "Flag cannot be empty!"                                           60
    [[ ${#flag} -gt 1 ]]                && caller >&2 && error $(eval echo "${ERR_INFO}") "Flag '${flag}' is invalid! Flags must be a single character!"    61
    [[ x"${description}" == x"" ]]      && caller >&2 && error $(eval echo "${ERR_INFO}") "Description for flag '${name}' cannot be empty!"                 62
    [[ x"${priority}" == x"" ]]         && caller >&2 && error $(eval echo "${ERR_INFO}") "Must provide a priority for flag '${name}'!"                     63
    [[ ! ${priority} =~ ^[0-9]+$ ]]     && caller >&2 && error $(eval echo "${ERR_INFO}") "Priority <${priority}> for flag '${name}' is not a number!"      64
    [[ x"${argument}" != x"" && ! ${valid_arg_types[@]} =~ "${argument_type}" ]] && {
        caller >&2
        error $(eval echo "${ERR_INFO}") "Flag argument type for '${name}':'${argument}' (${argument_type}) is invalid!" 65
    }

    # TODO: illegal key detection ( ' ; )

    # more complex validations
    for key in "${!valid_flags[@]}"; do # iterate over keys
        [[ "${valid_flags[${key}]}" == "${flag}" ]]             && caller >&2 && error $(eval echo "${ERR_INFO}") "Flag <${flag}> already registered!"                      66
    done

    for flag_name in "${!valid_flag_names[@]}"; do
        [[ "${valid_flag_names[${flag_name}]}" == "${name}" ]]  && caller >&2 && error $(eval echo "${ERR_INFO}") "Flag name <${flag_name}> already registered!"            67
    done

    [[ x"${argument}" != x"" ]] && {
        [[ x"${argument_type}" == x"" ]]    && caller >&2 && error $(eval echo "${ERR_INFO}") "Argument type must be provided for flag '${name}':'${argument}'"             68
        [[ x"${arg_description}" == x"" ]]  && caller >&2 && error $(eval echo "${ERR_INFO}") "Argument description must be provided for flag '${name}':'${argument}'"      69
    }

    # register information
    [[ "${flag}" != "-" ]] && valid_flags["${flag}"]="${name}"
    
    # description="${description//\${/\\\${}"

    local packed="'${flag}' '${name}' '${description//\'/\\\'}' '${priority}' '${argument}' '${argument_type}' '${arg_description//\'/\\\'}'"
    valid_flag_names[${name}]="${packed}"
}

# (1: variable)
function check_type () {
    local arg=$1

    local inferred_type

    if   [[ "${arg}" =~ ^[0-9]+$ ]]; then
        inferred_type="int"
    elif [[ "${arg}" =~ ^[+-]?[0-9]+\.?[0-9]*$ ]]; then
        inferred_type="float"
    elif [[ "$(declare -p arg)" =~ "declare -- arg=\""* ]]; then
        inferred_type="string"
    else
        error $(eval echo "${ERR_INFO}") "failed to determine type of '${arg}'" 255
    fi

    echo "${inferred_type}"
}

# (1: flag (single character))
function validate_flag () {
    local flag="$1"
    local valid_flag_found=0

    # check if the supplied flag is valid
    for value in "${!valid_flags[@]}"; do
        if [[ "${flag}" != "-" && "${value}" == "${flag}" ]]; then
            valid_flag_found=1
            break
        fi
    done

    # if no valid flag matching the supplied flag is found, error
    if [[ ${valid_flag_found} -eq 0 ]]; then
        error $(eval echo "${ERR_INFO}") "'-${flag}' is not a valid flag.\n\n$(print_help)" 255
    else
        local flag_name="${valid_flags[${flag}]}"
        local function_name="${flag_name//-/_}"

        local packed_flag_data="${valid_flag_names[${flag_name}]}"
        eval local unpacked_flag_data=(${packed_flag_data})

        #  0: flag (single character); 1: name; 2: description; 3: priority;
        #  4: argument name; 5: argument type; 6: argument description
        local flag_arg
        [[ x"${unpacked_flag_data[4]}" != x"" ]] && {
            # [[ x"${arguments[0]}" == x"" ]]
            flag_arg=" ${arguments[0]}"
            arr_pop arguments 0

            local inferred_type=$(check_type "${flag_arg}")
            [[ "${inferred_type}" != "${unpacked_flag_data[5]}" ]] && {
                local msg="Flag '${flag_name}' argument '${unpacked_flag_data[4]}' requires type '${unpacked_flag_data[5]}'. 
                    Inferred type of '${flag_arg}' is '${inferred_type}'"
                error $(eval echo "${ERR_INFO}") "${msg}" 255
            }
        }
        flag_unschedule+=("'${unpacked_flag_data[3]}' 'flag_name_${function_name}${flag_arg}'")
    fi
}

# (1: flag name (string))
function validate_flag_name () {
    local flag_name="$1"
    local valid_flag_name_found=0

    # check if the supplied flag is valid
    for value in "${!valid_flag_names[@]}"; do
        if [[ "${value}" == "${flag_name}" || "${value}" == "${flag//-/_}" ]]; then
            valid_flag_name_found=1
            break
        fi
    done

    # if no valid flag matching the supplied flag is found, error
    if [[ ${valid_flag_name_found} -eq 0 ]]; then
        error $(eval echo "${ERR_INFO}") "'--${flag_name}' is not a valid flag name.\n\n$(print_help)" 255
    else
        local function_name="${flag_name//-/_}"

        local packed_flag_data="${valid_flag_names[${flag_name}]}"
        eval local unpacked_flag_data=(${packed_flag_data})

        #  0: flag (single character); 1: name; 2: description; 3: priority;
        #  4: argument name; 5: argument type; 6: argument description
        local flag_arg
        if [[ x"${unpacked_flag_data[4]}" != x"" ]]; then
            [[ ${#arguments[@]} -eq 0 ]] \
                && error $(eval echo "${ERR_INFO}") "flag '${flag_name}' requires argument '${unpacked_flag_data[4]}' but wasn't provided!" 255

            flag_arg="${arguments[0]}"
            arr_pop arguments 0

            local inferred_type=$(check_type "${flag_arg}")
            [[ "${inferred_type}" != "${unpacked_flag_data[5]}" ]] && {
                local msg="Flag '${flag_name}' argument '${unpacked_flag_data[4]}' requires type '${unpacked_flag_data[5]}'. 
                    Inferred type of '${flag_arg}' is '${inferred_type}'"
                error $(eval echo "${ERR_INFO}") "${msg}" 255
            }
        fi
        flag_unschedule+=("'${unpacked_flag_data[3]}' 'flag_name_${function_name} ${flag_arg}'")
    fi
}

function validate_flags () {
    local arg="${arguments[0]}"

    if [[ "${arg:0:1}" != "-" ]]; then
        return
    fi

    arr_pop arguments 0

    if [[ "${arg:1:1}" != "-" ]]; then
        local flags=${arg}
        for (( i=1; i<${#flags}; i++ )); do
            validate_flag "${flags:$i:1}"
        done
    else
        validate_flag_name "${arg:2}"
    fi

    validate_flags
}

function execute_flags () {
    for (( i=0; i<10; i++ )); do
        for packed_item in "${flag_unschedule[@]}"; do
            eval local unpacked_item=(${packed_item})
            [[ ${unpacked_item[0]} -eq $i ]] && flag_schedule+=("${unpacked_item[1]}")
        done
    done

    for (( i=0; i<${#flag_schedule[@]}; i++ )); do
        eval ${flag_schedule[i]}
    done
}

function scrub_flags () {
    local FORCE="$1"

    unset -v flag_schedule flag_unschedule
    
    declare -ga flag_schedule
    declare -ga flag_unschedule
    
    if [[ ${PRESERVE_FLAGS} -eq 0 || x"${FORCE}" == x"force" ]]; then
        unset -v valid_flags valid_flag_names

        declare -gA valid_flags
        declare -gA valid_flag_names
    fi
}

function validate_target () {
    target=${arguments[0]}
    valid_target_found=0

    [[ ${#arguments[@]} -eq 0 ]] && print_help && exit 0

    arr_pop arguments 0

    [[ ! -f "targets/${target}.bash" && "$(is_builtin ${target})" == "n" ]] && \
        error $(eval echo "${ERR_INFO}") "Target file 'targets/${target}.bash' not found!" 255

    scrub_flags

    [[ "$(is_builtin ${target})" == "n" ]] \
        && source "targets/${target}.bash" \
        || eval "target_${target//-/_}_builtin"
    
    validate_flags
    execute_flags

    [[ $(type -t "target_${target//-/_}") != "function" ]] && \
        error $(eval echo "${ERR_INFO}") "Target function 'target_${target//-/_}' was not found in 'targets/${target}.bash'!" 255

    local target_arguments_provide=()
    for (( i=0; i<${#target_arguments[@]}; i++ )); do
        local arg_name="${target_arguments[i]}"
        local arg_type="${target_arg_types[i]}"

        if [[ "${arg_type}" != *... ]] then
            [[ ${#arguments[@]} -eq 0 ]] && \
                error $(eval echo "${ERR_INFO}") "Target '${target}' requires argument '${arg_name}' but wasn't provided!" 255
            
            local arg="${arguments[0]}"
            arr_pop arguments 0

            # TYPE CHECKING
            [[ "${arg_type}" != "any" && "${arg_type}" != "string" ]] && {
                local inferred_type=$(check_type "${arg}")
                [[ "${inferred_type}" != "${arg_type}" ]] && {
                    local msg="Target '${target}' argument '${arg_name}' requires type '${arg_type}'. \nInferred type of '${arg}' is '${inferred_type}'"
                    error $(eval echo "${ERR_INFO}") "${msg}" 255
                }
            }

            target_arguments_provide+=("\"${arg}\"")
        else # types containing '...' will consume all remaining arguments and check if they're all the same type.
            arg_type="${arg_type%%...}"
            local num_args=${#arguments[@]}
            for (( i=0; i<${num_args}; i++ )); do
                local arg="${arguments[0]}"
                arr_pop arguments 0

                # TYPE CHECKING
                [[ "${arg_type}" != "any" && "${arg_type}" != "string" ]] && {
                    local inferred_type=$(check_type "${arg}")
                    [[ "${inferred_type}" != "${arg_type}" ]] && {
                        local msg="Target '${target}' argument '${arg_name}' requires type '${arg_type}'. \nInferred type of '${arg}' is '${inferred_type}'"
                        error $(eval echo "${ERR_INFO}") "${msg}" 255
                    }
                }

                target_arguments_provide+=("${arg}")
            done; break
        fi
    done

    eval "target_${target//-/_}" ${target_arguments_provide[@]}
}

function is_builtin () {
    local target_check="$1"
    [[ ${builtin_targets[@]} =~ ${target_check} ]] && echo "y" || echo "n"
}

declare     current_target
declare -a  target_arguments
declare -a  target_arg_types
declare -a  target_arg_descs

# (1: name; 2: type; 3: description)
function add_argument () {
    local name=$1
    local type_=$2
    local desc=$3

    local detected_elipses=0
    [[ "${type_}" == *... ]] && {
        detected_elipses=1
        type_="${type_%%...}"
    }

    [[ x"${name}" == x"" || x"${desc}" == x"" || x"${type_}" == x"" || ! ${valid_arg_types[@]} =~ "${type_}" ]] && {
        echo "add_argument usage is: 'add_argument \"<name>\" \"<${valid_arg_types[*]}>\" \"<description>\"'" >&2
        echo "What you provided:" >&2
        echo "add_argument \"${name}\" \"${type_}\" \"${desc}\"" >&2
        exit 255
    }

    [[ ${detected_elipses} -eq 1 ]] && type_="${type_}..."
    local count=${#target_arguments[@]}

    target_arguments[$count]="${name}"
    target_arg_types[$count]="${type_}"
    target_arg_descs[$count]="${desc}"
}

# (1: target (optional); 2: is flag)
function print_help () {
    local cols=$(tput cols)
    cols=$(( $cols > 22 ? $cols - 1 : 20 ))

    local flag_help="$1"
    local is_flag="$2"

    if [[ x"${is_flag}" != x"" ]]; then
        return
    fi

    # print help for targets
    if [[ $# -gt 0 ]]; then
        # echo "[cmd][built-in][${flag_help}]: $(is_builtin ${flag_help})"
        if [[ ! -f "targets/${flag_help}.bash" && $(is_builtin "${flag_help}") == "n" ]]; then
            error $(eval echo "${ERR_INFO}") "No such command '${flag_help}'" 255

        elif [[ $(is_builtin "${flag_help}") == "y" ]]; then
            local current_target="${flag_help}"
            scrub_flags
            eval "target_${current_target}_builtin"
            local arg_count=${#target_arguments[@]}

            {
                echo ";name;priority;argument name;argument type   ;description"
                echo ";;;;;"
                for flag_name in "${!valid_flag_names[@]}"; do
                
                    # echo "${flag_name}"
                    local packed_flag_data="${valid_flag_names[${flag_name}]}"
                    # echo "${packed_flag_data}"
                    eval local flag_data=(${packed_flag_data})

                    #  1: flag (single character); 2: name; 3: description; 4: priority;
                    #  5: argument name; 6: argument type; 7: argument description
                    local flag="${flag_data[0]}"
                    local name="${flag_name}"
                    local description="${flag_data[2]}"
                    local priority="${flag_data[3]}"
                    local argument="${flag_data[4]}"
                    local argument_type="${flag_data[5]}"
                    local arg_description="${flag_data[6]}"

                    [[ "${flag}" == "-" ]] && flag="" || flag="-${flag}"

                    echo "${flag};--${name};${priority};;;${description}"
                    [[ x"${argument}" != x"" ]] && echo ";;;${argument};${argument_type};${arg_description}"
                    echo ";;;;;"

                done
            } | column  --separator ';'                                                                             \
                        --table                                                                                     \
                        --output-width ${cols}                                                                      \
                        --table-noheadings                                                                          \
                        --table-columns "short name,long name,priority,argument name,argument type,description"     \
                        --table-right "short name,priority"                                                         \
                        --table-wrap description
            
            {
                echo "target: ${current_target};description:;${description}"
                echo ";;"
                echo "argument name |;argument type |;description"
                echo ";;"

                for (( i=0; i<${arg_count}; i++ )); do
                    echo "${target_arguments[i]};${target_arg_types[i]};${target_arg_descs[i]}"
                done
            } | column                                      \
                    --separator ';'                         \
                    --table                                 \
                    --output-width ${cols}                  \
                    --table-noheadings                      \
                    --table-columns "argument name,argument type,description"  \
                    --table-wrap description 

        else
            local current_target="${flag_help}"
            
            scrub_flags
            description=""
            source "targets/${current_target}.bash"

            local arg_count=${#target_arguments[@]}

            {
                echo "target: ${current_target};description:;${description}"
                echo ";;"
                echo "argument name |;argument type |;description"
                echo ";;"

                for (( i=0; i<${arg_count}; i++ )); do
                    echo "${target_arguments[i]};${target_arg_types[i]};${target_arg_descs[i]}"
                done
            } | column                                      \
                    --separator ';'                         \
                    --table                                 \
                    --output-width ${cols}                  \
                    --table-noheadings                      \
                    --table-columns "argument name,argument type,description"  \
                    --table-wrap description 

            printf "%${cols}s\n" | tr " " "="

            {
                echo ";name;priority;argument name;argument type   ;description"
                echo ";;;;;"
                for flag_name in "${!valid_flag_names[@]}"; do
                
                    # echo "${flag_name}"
                    local packed_flag_data="${valid_flag_names[${flag_name}]}"
                    # echo "${packed_flag_data}"
                    eval local flag_data=(${packed_flag_data})

                    #  1: flag (single character); 2: name; 3: description; 4: priority;
                    #  5: argument name; 6: argument type; 7: argument description
                    local flag="${flag_data[0]}"
                    local name="${flag_name}"
                    local description="${flag_data[2]}"
                    local priority="${flag_data[3]}"
                    local argument="${flag_data[4]}"
                    local argument_type="${flag_data[5]}"
                    local arg_description="${flag_data[6]}"

                    [[ "${flag}" == "-" ]] && flag="" || flag="-${flag}"

                    echo "${flag};--${name};${priority};;;${description}"
                    [[ x"${argument}" != x"" ]] && echo ";;;${argument};${argument_type};${arg_description}"
                    echo ";;;;;"

                done
            } | column  --separator ';'                                                                             \
                        --table                                                                                     \
                        --output-width ${cols}                                                                      \
                        --table-noheadings                                                                          \
                        --table-columns "short name,long name,priority,argument name,argument type,description"     \
                        --table-right "short name,priority"                                                         \
                        --table-wrap description

        fi
    else # iterate through targets and collect info ; `$0 -h` or `$0 --help`
        echo "Main usage:"
        echo "    $0 [common-flag [flag-argument]]... <target> [target-flag [flag-argument]]... [target argument]..."
        echo
        echo "Help aliases:"
        echo "    $0"
        echo "    $0  -h"
        echo "    $0 --help"
        echo "    $0   help"
        echo
        echo "More detailed help aliases:"
        echo "    $0 --help-target <target>"
        echo

        echo "Common Flags:"
        {
            echo ";name;priority;argument name;argument type   ;description"
            echo ";;;;;"
            for flag_name in "${!valid_flag_names[@]}"; do
            
                # echo "${flag_name}"
                local packed_flag_data="${valid_flag_names[${flag_name}]}"
                # echo "${packed_flag_data}"
                eval local flag_data=(${packed_flag_data})

                #  1: flag (single character); 2: name; 3: description; 4: priority;
                #  5: argument name; 6: argument type; 7: argument description
                local flag="${flag_data[0]}"
                local name="${flag_name}"
                local description="${flag_data[2]}"
                local priority="${flag_data[3]}"
                local argument="${flag_data[4]}"
                local argument_type="${flag_data[5]}"
                local arg_description="${flag_data[6]}"

                [[ "${flag}" == "-" ]] && flag="" || flag="-${flag}"

                echo "${flag};--${name};${priority};;;${description}"
                [[ x"${argument}" != x"" ]] && echo ";;;${argument};${argument_type};${arg_description}"
                echo ";;;;;"

            done
        } | column  --separator ';'                                                                             \
                    --table                                                                                     \
                    --output-width ${cols}                                                                      \
                    --table-noheadings                                                                          \
                    --table-columns "short name,long name,priority,argument name,argument type,description"     \
                    --table-right "short name,priority"                                                         \
                    --table-wrap description
        
        echo "Targets:"
        {
            echo ";;;"
            for file in targets/*.bash; do
                current_target="${file##*/}"
                current_target="${current_target%.bash}"

                [[ "${current_target}" == "common" ]] && continue

                # echo "${current_target}" >&2
                
                target_arguments=()
                target_arg_types=()
                target_arg_descs=()

                scrub_flags "force"
                description=""
                source ${file}

                local flag_count=${#valid_flag_names[@]}
                local arg_count=${#target_arguments[@]}

                echo "${current_target};${flag_count};${arg_count};${description}"
                echo ";;;"
            done
        } | column                                                              \
                --separator ';'                                                 \
                --table                                                         \
                --output-width ${cols}                                          \
                --table-columns "subcommand,flag count,arg count,description"   \
                --table-wrap description 
    fi
}



# ================================================================================================
#                                            BUILT-INS
add_flag "h" "help" "prints this menu" 0
function flag_name_help () {
    print_help
    exit 0
}

add_flag "-" "help-target" "prints help for a specific target" 0 "target" "string" "prints a target-specific help with more info"
function flag_name_help_target () {
    print_help $1
    exit 0
}

add_flag "-" "debug--preserve-flags" "prevents unsetting flags before loading targets" 0
function flag_name_debug__preserve_flags () {
    PRESERVE_FLAGS=1
}

add_flag "-" "ignore-deps" "does not perform dependency validation" 0
function flag_name_ignore_deps () {
    IGNORE_DEPENDENCIES=1
}


builtin_targets+=("help")
function target_help_builtin () {
    description="prints this menu"
}
function target_help () {
    print_help
}

