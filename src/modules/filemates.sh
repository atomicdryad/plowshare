#!/bin/bash
#
# filemates.com module
# Copyright (c) 2012 Plowshare team
#
# This file is part of Plowshare.
#
# Plowshare is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Plowshare is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Plowshare.  If not, see <http://www.gnu.org/licenses/>.
#
# Note: This module is a clone of ryushare.

MODULE_FILEMATES_REGEXP_URL="http://\(www\.\)\?filemates\.com/"

MODULE_FILEMATES_DOWNLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=USER:PASSWORD,Free account
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_FILEMATES_DOWNLOAD_RESUME=no
MODULE_FILEMATES_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_FILEMATES_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_FILEMATES_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account (mandatory)
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
FOLDER,,folder,s=FOLDER,Folder to upload files into
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
PREMIUM,,premium,,Make file inaccessible to non-premium users
PRIVATE_FILE,,private,,Do not make file visible in folder view
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email"
MODULE_FILEMATES_UPLOAD_REMOTE_SUPPORT=yes

MODULE_FILEMATES_DELETE_OPTIONS=""

MODULE_FILEMATES_LIST_OPTIONS=""

# Static function. Proceed with login (free or premium)
# $1: authentication
# $2: cookie file
# $3: base url
# stdout: account type ("free" or "premium") on success
filemates_login() {
    local -r AUTH_FREE=$1
    local -r COOKIE_FILE=$2
    local -r BASE_URL=$3
    local LOGIN_DATA PAGE NAME ACCOUNT

    LOGIN_DATA='login=$USER&password=$PASSWORD'
    PAGE=$(post_login "$AUTH_FREE" "$COOKIE_FILE" \
        "op=login&redirect=${BASE_URL}&${LOGIN_DATA}" "$BASE_URL" \
        -b "$COOKIE_FILE") || return

    # Note: Successfull login is empty (redirects) and sets cookies: login xfss
    NAME=$(parse_cookie_quiet 'login' < "$COOKIE_FILE")
    [ -n "$NAME" ] || return $ERR_LOGIN_FAILED

    # Determine account type
    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/?op=my_account") || return
    ACCOUNT=$(echo "$PAGE" | parse 'User level' '^[[:space:]]*\([^<]*\)' 3)

    if match '^[[:space:]]*Free' "$PAGE"; then
        ACCOUNT='free'
    # Note: educated guessing for now
    elif match '^[[:space:]]*Premium' "$HTML"; then
        ACCOUNT='premium'
    else
        log_error 'Could not determine account type. Site updated?'
        return $ERR_FATAL
    fi

    log_debug "Successfully logged in as $ACCOUNT member '$NAME'"
    echo "$ACCOUNT"
}

# Static function. Switch language to english
# $1: cookie file
# $2: base URL
filemates_switch_lang() {
    # Note: Server reply is empty (redirects)
    curl -b "$1" -c "$1" -d 'op=change_lang' -d 'lang=english' "$2" || return
}

# Check if specified folder name is valid.
# When multiple folders wear the same name, first one is taken.
# $1: folder name selected by user
# $2: base URL
# $3: cookie file (logged into account)
# stdout: folder ID
filemate_check_folder() {
    local -r NAME=$1
    local -r BASE_URL=$2
    local -r COOKIE_FILE=$3
    local PAGE FORM FOLDERS FOL FOL_ID

    # Special treatment for root folder (always uses ID "0")
    if [ "$NAME" = '/' ]; then
        echo 0
        return 0
    fi

    # Retrieve "My Files" page
    PAGE=$(curl -b "$COOKIE_FILE" -d 'op=my_files' "$BASE_URL") || return
    FORM=$(grep_form_by_name "$PAGE" 'F1') || return

    # <option value="ID">&nbsp;NAME</option>
    # Note: - Site uses "&nbsp;" to indent sub folders
    #       - First entry is label "Move files to folder"
    #       - Second entry is root folder "/"
    FOLDERS=$(echo "$FORM" | parse_all_tag option | delete_first_line 2 |
        replace '&nbsp;' '') || return
    if [ -z "$FOLDERS" ]; then
        log_error "No folder found, site updated?"
        return $ERR_FATAL
    fi

    log_debug 'Available folders:' $FOLDERS

    while IFS= read -r FOL; do
        if [ "$FOL" = "$NAME" ]; then
            FOL_ID=$(echo "$FORM" | \
                parse_attr "^<option.*$FOL</option>" 'value') || return
            echo "$FOL_ID"
            return 0
        fi
    done <<< "$FOLDERS"

    log_error "Invalid folder, choose from:" $FOLDERS
    return $ERR_BAD_COMMAND_LINE
}

# Output a filemates file download URL
# $1: cookie file
# $2: filemates url
# stdout: real file download link
filemates_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://filemates.com'
    local PAGE FILE_URL ACCOUNT ERR CODE
    local FORM_HTML FORM_OP FORM_USR FORM_ID FORM_FNAME FORM_RAND FORM_METHOD

    filemates_switch_lang "$COOKIE_FILE" "$BASE_URL"

    if [ -n "$AUTH_FREE" ]; then
        ACCOUNT=$(filemates_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL") || return

        [ "$ACCOUNT" != 'free' ] && log_error 'Premium users not handled. Sorry'
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$URL") || return

    # The file was removed by administrator
    # The file was deleted by ...
    if matchi 'file was \(removed\|deleted\)' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    # Send (post) form
    # Note: usr_login is empty even if logged in
    FORM_HTML=$(grep_form_by_order "$PAGE" 1) || return
    FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op') || return
    FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id') || return
    FORM_USR=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'usr_login')
    FORM_FNAME=$(echo "$FORM_HTML" | parse_form_input_by_name 'fname') || return
    FORM_METHOD=$(echo "$FORM_HTML" | parse_form_input_by_name_quiet 'method_free')

    PAGE=$(curl -b "$COOKIE_FILE" -F 'referer=' \
        -F "op=$FORM_OP" \
        -F "usr_login=$FORM_USR" \
        -F "id=$FORM_ID" \
        -F "fname=$FORM_FNAME" \
        -F "method_free=$FORM_METHOD" "$URL") || return

    # You can download files up to 400 Mb only.
    # Upgrade your account to download bigger files.
    if match 'You can download files up to .* only' "$PAGE"; then
        return $ERR_SIZE_LIMIT_EXCEEDED

    # You need to upgrade to Premium to download this file!
    elif match 'upgrade to Premium to download this file' "$PAGE"; then
        return $ERR_LINK_NEED_PERMISSIONS

    # You have to wait X minutes, Y seconds till next download
    elif matchi 'You have to wait' "$PAGE"; then
        local MINS SECS
        MINS=$(echo "$PAGE" | \
            parse_quiet 'class="err"' 'wait \([[:digit:]]\+\) minute')
        SECS=$(echo "$PAGE" | \
            parse_quiet 'class="err"' ', \([[:digit:]]\+\) second')

        log_error 'Forced delay between downloads.'
        echo $(( MINS * 60 + SECS ))
        return $ERR_LINK_TEMP_UNAVAILABLE

    # File Password (ask the uploader to give you this key)
    elif match '"password"' "$PAGE"; then
        log_debug 'File is password protected'
        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD=$(prompt_for_password) || return
        fi

    elif match '<div class="err"' "$PAGE"; then
        ERR=$(echo "$PAGE" | parse_tag 'class="err"' div)
        log_error "Remote error: $ERR"
    fi

    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1') || return
    FORM_OP=$(echo "$FORM_HTML" | parse_form_input_by_name 'op') || return
    FORM_ID=$(echo "$FORM_HTML" | parse_form_input_by_name 'id') || return
    FORM_RAND=$(echo "$FORM_HTML" | parse_form_input_by_name 'rand') || return
    FORM_METHOD=$(echo "$FORM_HTML" | parse_form_input_by_name 'method_free') || return

    # Funny captcha, this is text (4 digits)!
    # Copy/Paste from uptobox
    if match 'Enter code below:' "$PAGE"; then
        local CAPTCHA DIGIT XCOORD LINE

        CAPTCHA=$(echo "$FORM_HTML" | parse_tag 'direction:ltr' div | \
            sed -e 's/span>/span>\n/g') || return
        CODE=0
        while read LINE; do
            DIGIT=$(echo "$LINE" | parse 'padding-' '>&#\([[:digit:]]\+\);<') || return
            XCOORD=$(echo "$LINE" | parse 'padding-' '-left:\([[:digit:]]\+\)p') || return

            # Depending x, guess digit rank
            if (( XCOORD < 15 )); then
                (( CODE = CODE + 1000 * (DIGIT-48) ))
            elif (( XCOORD < 30 )); then
                (( CODE = CODE + 100 * (DIGIT-48) ))
            elif (( XCOORD < 50 )); then
                (( CODE = CODE + 10 * (DIGIT-48) ))
            else
                (( CODE = CODE + (DIGIT-48) ))
            fi
        done <<< "$CAPTCHA"
    fi

    # <span id="countdown_str">Wait <span id="phmz1e">60</span> seconds</span>
    WAIT_TIME=$(echo "$PAGE" | parse_tag countdown_str span) || return
    wait $((WAIT_TIME + 1)) || return

    # Didn't included -d 'method_premium='
    PAGE=$(curl -b "$COOKIE_FILE" -d "referer=$URL" \
        -d "op=$FORM_OP" \
        -d "id=$FORM_ID" \
        -d "rand=$FORM_RAND" \
        -d "method_free=$FORM_METHOD" \
        -d "password=$LINK_PASSWORD" \
        -d "code=$CODE" \
        "$URL" | break_html_lines) || return

    FILE_URL=$(echo "$PAGE" | parse_attr_quiet 'srv[[:digit:]]' href)
    test -z "$FILE_URL" && \
        FILE_URL=$(echo "$PAGE" | parse_quiet 'srv[[:digit:]]' "Do('\([^']*\)")
    if match_remote_url "$FILE_URL"; then
        echo "$FILE_URL"
        echo "$FORM_FNAME"
        return 0
    fi

    if match '<div class="err"' "$PAGE"; then
        ERR=$(echo "$PAGE" | parse_tag 'class="err"' div)
        if match 'Wrong password' "$ERR"; then
            return $ERR_LINK_PASSWORD_REQUIRED
        elif match 'Wrong captcha' "$ERR"; then
            return $ERR_CAPTCHA
        fi
        log_error "Remote error: $ERR"
    else
        log_error 'Unexpected content, site updated?'
    fi

    return $ERR_FATAL
}

# Upload a file to FileMates
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
#         delete link
filemates_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DEST_FILE=$3
    local -r BASE_URL='http://filemates.com'
    local -r MAX_SIZE=5368709120 # up to 5 GiB
    local PAGE FORM SRV_URL SRV_BASE_URL UP_ID SESS_ID FILE_CODE STATE
    local LINK DEL_LINK FOLDER_ID REN_REMOTE

    [ -n "$AUTH_FREE" ] || return $ERR_LINK_NEED_PERMISSIONS

    # Check size limit for local uploads
    if ! match_remote_url "$FILE"; then
        local SIZE

        SIZE=$(get_filesize "$FILE") || return
        if [ $SIZE -gt $MAX_SIZE ]; then
            log_debug "File is bigger than $MAX_SIZE"
            return $ERR_SIZE_LIMIT_EXCEEDED
        fi
    fi

    # Check for forbidden file extensions
    # Note: Remote upload allows these extension but the completed files cannot
    #       be renamed to have an forbidden extension
    case ${DEST_FILE##*.} in
        php|pl|cgi|py|sh|shtml)
            log_error 'File extension is forbidden. Try renaming your file.'
            return $ERR_FATAL
            ;;
    esac

    filemates_switch_lang "$COOKIE_FILE" "$BASE_URL"
    filemates_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" > /dev/null || return

    # If user chose a folder, check it now
    # Note: This needs to go after login.
    if [ -n "$FOLDER" ]; then
        FOLDER_ID=$(filemate_check_folder "$FOLDER" "$BASE_URL" "$COOKIE_FILE") || return
        log_debug "Folder ID: '$FOLDER_ID'"
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL") || return

    # Gather relevant data
    FORM=$(grep_form_by_name "$PAGE" 'file') || return
    SESS_ID=$(echo "$FORM" | parse_form_input_by_name_quiet 'sess_id') || return
    SRV_URL=$(echo "$FORM" | parse_form_input_by_name 'srv_tmp_url') || return
    SRV_BASE_URL=$(basename_url "$SRV_URL") || return
    UP_ID=$(random d 12) || return

    log_debug "Session ID: '$SESS_ID'"
    log_debug "Server URL: '$SRV_URL'"

    # Prepare upload
    PAGE=$(curl -b "$COOKIE_FILE" \
        "${SRV_URL}/status.html?$UP_ID=$DEST_FILE=filemates.com") || return

    if ! match 'Initializing upload...' "$PAGE"; then
        log_error 'Unexpected content. Site updated?'
        return $ERR_FATAL
    fi

    # Upload file
    # Note: Password is set later on to simplify things a bit
    if ! match_remote_url "$FILE"; then
        PAGE=$(curl_with_log -b "$COOKIE_FILE" \
            -F 'upload_type=file' \
            -F "sess_id=$SESS_ID" \
            -F "srv_tmp_url=$SRV_URL" \
            -F "file_0=@$FILE;type=application/octet-stream;filename=$DEST_FILE" \
            -F 'file_1=;filename=' \
            -F "link_rcpt=$TOEMAIL" \
            -F 'link_pass=' \
            -F 'tos=1' \
            -F 'submit_btn= Upload! ' \
            "$SRV_BASE_URL/cgi-bin/upload.cgi?upload_id=$UP_ID&js_on=1&utype=reg&upload_type=file") || return

    else
        PAGE=$(curl_with_log -b "$COOKIE_FILE" \
            -F "sess_id=$SESS_ID" \
            -F 'upload_type=url' \
            -F "srv_tmp_url=$SRV_URL" \
            -F "url_mass=$FILE" \
            -F 'url_proxy=' \
            -F "link_rcpt=$TOEMAIL" \
            -F 'link_pass=' \
            -F 'tos=1' \
            -F 'submit_btn= Upload! ' \
            "$SRV_BASE_URL/cgi-bin/upload.cgi?upload_id=$UP_ID&js_on=1&utype=reg&upload_type=url") || return

        # Remember if we need to rename the file
        [ "$DEST_FILE" != 'dummy' ] && REN_REMOTE='yes'
    fi

    # Gather relevant data
    FORM=$(grep_form_by_name "$PAGE" 'F1' | break_html_lines) || return
    FILE_CODE=$(echo "$FORM" | parse_tag 'fn' 'textarea') || return
    STATE=$(echo "$FORM" | parse_tag 'st' 'textarea') || return

    log_debug "File Code: '$FILE_CODE'"
    log_debug "State: '$STATE'"

    if [ "$STATE" = 'OK' ]; then
        log_debug 'Upload successfull.'
    elif [ "$STATE" = 'unallowed extension' ]; then
        log_error 'File extension is forbidden.'
        return $ERR_FATAL
    else
        log_error "Unknown upload state: $STATE"
        return $ERR_FATAL
    fi

    # Get download URL
    # Note: At this point we know the upload state is "OK" due to "if" above
    PAGE=$(curl -b "$COOKIE_FILE" \
        -F "fn=$FILE_CODE" \
        -F 'st=OK' \
        -F 'op=upload_result' \
        "$BASE_URL") || return

    LINK=$(echo "$PAGE" | parse 'Download Link' '>\(http[^<]\+\)<' 1) || return
    DEL_LINK=$(echo "$PAGE" | parse 'Delete Link' '>\(http[^<]\+\)<' 1) || return

    # Move file to a folder?
    # Note: This goes before the extended file properties to make things easier
    if [ -n "$FOLDER" ]; then
        log_debug 'Moving file...'
        local FILE_ID

        # Retrieve "My Files" page
        PAGE=$(curl -b "$COOKIE_FILE" -d 'op=my_files' "$BASE_URL") || return
        FORM=$(grep_form_by_name "$PAGE" 'F1') || return

        # <TD><input type="checkbox" name="file_id" value="123456"></TD>
        # <TD align=left><a href="http://...">file name</a></TD>
        FILE_ID=$(echo "$FORM" | parse "$LINK" '^\(.*\)$' -1 | \
            parse_form_input_by_name 'file_id') || return

        # Move to destination folder
        # Note: Source folder ("fld_id") is always root ("0") for newly uploaded files
        PAGE=$(curl -b "$COOKIE_FILE" -i \
            -F 'op=my_files' \
            -F 'fld_id=0' \
            -F 'key=' \
            -F 'create_new_folder=' \
            -F "file_id=$FILE_ID" \
            -F "to_folder=$FOLDER_ID" \
            -F 'to_folder_move=Move files' \
            "$BASE_URL") || return

        PAGE=$(echo "$PAGE" | grep_http_header_location_quiet)
        match '?op=my_files' "$PAGE" || log_error 'Could not move file. Site update?'
    fi

    # Edit the file? (description, password, visibility, premium-only)
    if [ -n "$DESCRIPTION" -o -z "$PRIVATE_FILE" -o -n "$PREMIUM" -o \
        -n "$LINK_PASSWORD" -o -n "$REN_REMOTE" ]; then

        log_debug 'Editing file...'
        local F_NAME F_DESC F_PASS F_PUB F_PREM REDIR

        # Set values
        [ -n "$DESCRIPTION" ] && F_DESC=$DESCRIPTION
        [ -n "$LINK_PASSWORD" ] && F_PASS=$LINK_PASSWORD
        [ -z "$PRIVATE_FILE" ] && F_PUB=1
        [ -n "$PREMIUM" ] && F_PREM=1

        # Parse file name from URL for remote files if we do not rename them
        if match_remote_url "$FILE" && [ "$DEST_FILE" = 'dummy' ]; then
            F_NAME=${LINK##*/}
        else
            F_NAME=$DEST_FILE
        fi

        # Post changes (include HTTP headers to check for proper redirection)
        PAGE=$(curl -i -b "$COOKIE_FILE" \
            -F 'op=file_edit' \
            -F "file_code=$FILE_CODE" \
            -F "file_name=$F_NAME" \
            -F "file_descr=$F_DESC" \
            -F "file_password=$F_PASS" \
            -F "file_public=$F_PUB" \
            -F "file_premium_only=$F_PREM" \
            -F 'save= Submit ' \
            "${BASE_URL}?op=file_edit;file_code=$FILE_CODE") || return

        REDIR=$(echo "$PAGE" | grep_http_header_location_quiet)

        if match '?op=my_files' "$REDIR"; then
            # When the name changes, we need to adapt the links too
            if [ -n "$REN_REMOTE" ]; then
                log_debug 'Updating Links...'

                # Use short version of link to get download page and parse full link from it
                # Note: $DEST_FILE is no good due to character substitution done by server
                PAGE=$(curl ${LINK%/*}) || return
                LINK=$(echo "$PAGE" | parse_attr 'You have requested' 'value') || return
                DEL_LINK="${LINK}?${DEL_LINK##*\?}"
            fi

        elif match 'Filename too short' "$PAGE"; then
            log_error 'Filename is too short'

        else
            log_error 'Could not edit file. Site update?'
        fi
    fi

    echo "$LINK"
    echo "$DEL_LINK"
}

# Delete a file on FileMates
# $1: cookie file
# $2: kill URL
filemates_delete() {
    local -r COOKIE_FILE=$1
    local URL=$2
    local -r BASE_URL='http://filemates.com'
    local PAGE FILE_ID KILL_CODE

    filemates_switch_lang "$COOKIE_FILE" "$BASE_URL" || return

    PAGE=$(curl -i -b "$COOKIE_FILE" -L "$URL") || return

    # <font class="ok">File deleted successfully</font><br><br>
    if match 'No such file exist' "$PAGE"; then
        return $ERR_LINK_DEAD

    # <font style="color:#d33;">Wrong Delete ID</font>
    elif match 'Wrong Delete ID' "$PAGE"; then
        log_error 'You provided a wrong kill code'
        return $ERR_FATAL

    # Do you want to delete file: <b><FILE_NAME></b> ?<br><br>
    elif match 'Do you want to delete file' "$PAGE"; then

        # Check + parse redirection URL (easier to parse than original URL)
        URL=$(echo "$PAGE" | grep_http_header_location) || return
        FILE_ID=$(echo "$URL" | parse . '&id=\([[:alnum:]]\{12\}\)') || return
        KILL_CODE=$(echo "$URL" | parse . '&del_id=\([[:alnum:]]\{10\}\)') || return

        PAGE=$(curl -b "$COOKIE_FILE" -F 'op=del_file' -F "id=$FILE_ID" \
            -F "del_id=$KILL_CODE" -F 'confirm=yes' "$BASE_URL") || return

        # <font class="ok">File deleted successfully</font><br><br>
        match 'File deleted successfully' "$PAGE" && return 0
    fi

    log_error 'Unexpected content. Site updated?'
    return $ERR_FATAL
}

# List a FileMates web folder URL
# $1: folder URL
# $2: recurse subfolders (null string means not selected)
# stdout: list of links and file names (alternating)
filemates_list() {
    local -r URL=$1
    local -r REC=$2
    local -r BASE_URL='http://filemates.com'
    local RET=$ERR_LINK_DEAD
    local PAGE LINKS NAMES

    PAGE=$(curl "$URL") || return
    LINKS=$(echo "$PAGE" | parse_all_attr 'class="link"' 'href') || return
    NAMES=$(echo "$PAGE" | parse_all_tag 'class="link"' 'a') || return

    list_submit "$LINKS" "$NAMES" && RET=0

    # Are there any subfolders?
    if [ -n "$REC" ]; then
        local FOLDERS FOLDER

        FOLDERS=$(echo "$PAGE" | parse_all_attr 'folder2.gif' 'href') || return

        # First folder can be parent folder (". .") - drop it to avoid infinite loops
        FOLDER=$(echo "$PAGE" | parse_tag 'folder2.gif' 'b') || return
        [ "$FOLDER" = '. .' ] && FOLDERS=$(echo "$FOLDERS" | delete_first_line)

        while read FOLDER; do
            [ -z "$FOLDER" ] && continue
            log_debug "entering sub folder: $FOLDER"
            filemates_list "$FOLDER" "$REC" && RET=0
        done <<< "$FOLDERS"
    fi

    return $RET
}
