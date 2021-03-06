# --------------------------------------------------------------------
# Copyright (c) 2020 Anthony Potappel - LINKIT, The Netherlands.
# SPDX-License-Identifier: MIT
# --------------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" = "${0}" ]];then
    echo "script ${BASH_SOURCE[0]} can only be sourced"
    exit 1
fi

set -o pipefail

DEFAULT_REGION='eu-west-1'
DEFAULT_PROFILE='runtime_default'


configuration_warning(){
    # be verbose if minimal environment vars are missing
    echo "WARNING: missing environment variable $1"
    export SHOW_WARNING=1
    return 0
}


whoami(){
    # retrieve current AWS identity
    if [ -z ${AWS_SECRET_ACCESS_KEY} ] \
       || [ -z ${AWS_ACCESS_KEY_ID} ];then
            echo 'No AWS credentials configured'
    else
        echo 'AWS credentials used:'
        aws sts get-caller-identity
        echo "AWS default region set: ${AWS_DEFAULT_REGION}"
    fi
    echo "Environment runs as user: $(/usr/bin/whoami)"
    return 0
}


get_credentials(){
    # get temporary credentials via sts
    role_credentials=$(aws sts assume-role \
      --role-arn ${1} \
      --role-session-name __auto__ \
        |jq -r  '.Credentials
                 | .["AWS_ACCESS_KEY_ID"] = .AccessKeyId
                 | .["AWS_SECRET_ACCESS_KEY"] = .SecretAccessKey
                 | .["AWS_SESSION_TOKEN" ] = .SessionToken
                 | {AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN}
                 | to_entries
                 | map("\(.key)=\(.value|tostring)") 
                 | .[]' \
    ) || return 1
    printf "${role_credentials}"
    return $?
}


credentials_defined(){
    # check if minimal credentials are define in environment
    if [ -z ${_RUNTIME_AWS_SECRET_ACCESS_KEY} ] \
       || [ -z ${_RUNTIME_AWS_ACCESS_KEY_ID} ];then
           [ -z ${_RUNTIME_AWS_SECRET_ACCESS_KEY} ] \
               && configuration_warning 'AWS_SECRET_ACCESS_KEY'
           [ -z ${_RUNTIME_AWS_ACCESS_KEY_ID} ] \
               && configuration_warning 'AWS_ACCESS_KEY_ID'
        return 1
    fi
    return 0
}


register_profile(){
    # Update profile ${1} in  ~/.aws/[config,credentials]
    # values based on current AWS_-environment settings
    profile_name=${1}

    # to prevent a chicken-egg-type situation temporarily disable env profile
    # if it is the same one we are registering
    if [ ! -z ${AWS_PROFILE} ] && [ ${AWS_PROFILE} == ${profile_name} ];then
        _TMP_AWS_PROFILE=${AWS_PROFILE}
        unset AWS_PROFILE
    fi

    aws configure set \
        region ${AWS_DEFAULT_REGION} --profile ${profile_name} \
    && aws configure set \
        aws_access_key_id ${AWS_ACCESS_KEY_ID} --profile ${profile_name} \
    && aws configure set \
        aws_secret_access_key ${AWS_SECRET_ACCESS_KEY} --profile ${profile_name} \
    || return 1

    if [ ! -z ${AWS_SESSION_TOKEN} ];then
        aws configure set \
            aws_session_token ${AWS_SESSION_TOKEN} --profile ${profile_name} \
        || return 1
    fi

    # restore disabled profile
    [ ! -z ${_TMP_AWS_PROFILE} ] && export AWS_PROFILE=${_TMP_AWS_PROFILE}

    return 0
}


credentials_from_role(){
    # retrieve role based credentials
    # export to environment and  update profile configuration
    role_arn=${1}
    profile_name=${2}

    [ -z ${profile_name} ] && \
        profile_name=$(basename ${role_arn})

    export $(get_credentials ${role_arn}) \
        && register_profile ${profile_name} \
        && export AWS_PROFILE=${profile_name} \
        && export AWS_ROLE_ARN=${role_arn}
    return $?
}


set_default_credentials(){
    # on first run: credential information is copied "TO" _RUNTIME_{VAR}
    # on consecutive runs: credential information is copied "FROM" _RUNTIME_${VAR}
    # 
    # these mechanics allow to acquire (and export) new (role-based) credentials,
    # with the option to switch back to the credentials set on initial runtime

    if [ ! -z "${_RUNTIME_AWS_DEFAULT_REGION}" ];then
        # consecutive run -- retrieve credentials from originating runtime
        credentials_defined || return 1

        export AWS_ACCESS_KEY_ID=${_RUNTIME_AWS_ACCESS_KEY_ID}
        export AWS_SECRET_ACCESS_KEY=${_RUNTIME_AWS_SECRET_ACCESS_KEY}
        export AWS_DEFAULT_REGION=${_RUNTIME_AWS_DEFAULT_REGION}
        export AWS_REGION=${AWS_DEFAULT_REGION}

        # optional vars - only define if _RUNTIME var is non-empty
        [ ! -z ${_RUNTIME_AWS_SESSION_TOKEN} ] \
            && export AWS_SESSION_TOKEN=${_RUNTIME_AWS_SESSION_TOKEN}

        [ ! -z ${_RUNTIME_AWS_ROLE_ARN} ] \
            && export AWS_ROLE_ARN=${_RUNTIME_AWS_ROLE_ARN}

        [ ! -z ${_RUNTIME_S3_BUCKET} ] \
            && export S3_BUCKET=${_RUNTIME_S3_BUCKET}

        [ ! -z ${_RUNTIME_S3_PREFIX} ] \
            && export S3_PREFIX=${_RUNTIME_S3_PREFIX}

        # env is back at the default profile
        # export AWS_PROFILE=${DEFAULT_PROFILE}
        export AWS_PROFILE=${_RUNTIME_AWS_PROFILE}
    else
        # first run -- store credentials so it can be retrieved on consecutive runs
        # region must be set - if empty, use default
        if [ -z ${AWS_DEFAULT_REGION} ];then
            export AWS_DEFAULT_REGION=${DEFAULT_REGION}
        fi

        [ -z ${AWS_PROFILE} ] && export AWS_PROFILE=${DEFAULT_PROFILE}
        register_profile ${AWS_PROFILE}

        export AWS_REGION=${AWS_DEFAULT_REGION}
        export _RUNTIME_AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}
        export _RUNTIME_AWS_PROFILE=${AWS_PROFILE}

        export _RUNTIME_AWS_ROLE_ARN=${AWS_ROLE_ARN}
        # ensure role based credentials run before setting default
        # _RUNTIME_${CREDENTIALS} as environment vars are altered by it
        if [ ! -z ${AWS_ROLE_ARN} ];then
            # credentials_from_role ${AWS_ROLE_ARN} ${DEFAULT_PROFILE}
            credentials_from_role ${AWS_ROLE_ARN} ${AWS_PROFILE}
        fi

        export _RUNTIME_AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
        export _RUNTIME_AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}

        # optional vars -- can be empty
        export _RUNTIME_AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN}
        export _RUNTIME_S3_BUCKET=${S3_BUCKET}
        export _RUNTIME_S3_PREFIX=${S3_PREFIX}

        credentials_defined || return 1
        whoami
    fi
    return 0
}

custom_role_arn=${1}
custom_profile_name=${2}

# both initiation and updates must start from default credentials
set_default_credentials

# switch credentials during runtime if custom_role_arn is set
if [ ! -z ${custom_role_arn} ];then
    credentials_from_role ${custom_role_arn} "${custom_profile_name}" \
        && whoami \
        || set_default_credentials
fi

return 0
