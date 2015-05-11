%% Erlang support for LLSN - Allyst's data interchange format.
%% LLSN specification http://allyst.org/opensource/llsn/
%%
%% This program is free software; you can redistribute it and/or modify
%% it under the terms of the GNU General Public License as published by
%% the Free Software Foundation; either version 3 of the License, or
%% (at your option) any later version.
%%
%% This program is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU Library General Public License for more details.
%%
%% Full license: https://github.com/allyst/go-llsn/blob/master/LICENSE
%%
%% copyright (C) 2014 Allyst Inc. http://allyst.com
%% author Taras Halturin <halturin@allyst.com>

-module(llsn).

-include("llsn.hrl").

-export([encode/2, encode/3, encode/4, encode/5]).

-export([encode_NUMBER/1]).

% encode options
-record (options, {
    % threshold for the huge data (string, blob, file). put it to the end of packet
    threshold :: non_neg_integer(), 
    pid, % send frames of the encoded data to the PID
    framesize, % frame size limit 
    frame :: non_neg_integer(), % frame number
    binsize, % current size of encoded data
    userdata :: list(), % use it with framing encode data
    tail, % list of the huge items
    stack, % needs for incapsulated structs/arrays
    struct, % needs for POINTER type processing
    tt % tree of the types
}).

-record (typestree, {
    type        :: non_neg_integer,
    length      :: non_neg_integer(),
    parent,
    child,
    prev,
    next,
    nullflag                  
}).



%% =============================================================================
%% Encoding
%% =============================================================================
% with no framing and default threshold

encode(Packet, Struct) when is_tuple(Packet) and is_tuple(Struct) ->
    Options = #options{
        threshold = ?LLSN_DEFAULT_THRESHOLD,
        framesize = ?LLSN_DEFAULT_FRAME_SIZE,
        frame = 1,
        binsize = 0,
        tail = [],
        stack = [],
        tt = typestree(new)
    },
    encode_ext(Packet, Struct, Options).

% with framing and default threshold
encode(Packet, Struct, PID) when is_pid(PID)
        and is_tuple(Packet) and is_tuple(Struct) ->
    Options = #options{
        threshold = ?LLSN_DEFAULT_THRESHOLD,
        framesize = ?LLSN_DEFAULT_FRAME_SIZE,
        frame = 1,
        binsize = 0,
        tail = [],
        stack = [],
        pid = PID,
        tt = typestree(new)
    },
    encode_ext(Packet, Struct, Options);


% no framing and custom threshold
encode(Packet, Struct, Threshold) when is_integer(Threshold)
        and is_tuple(Packet) and is_tuple(Struct) ->
    Options = #options{
        threshold = Threshold,
        framesize = ?LLSN_DEFAULT_FRAME_SIZE,
        frame = 1,
        binsize = 0,
        tail = [],
        stack = [],
        tt = typestree(new)
    },
    encode_ext(Packet, Struct, Options).

encode(Packet, Struct, PID, UserData) when is_pid(PID)
        and is_tuple(Packet) and is_tuple(Struct)
        and is_list(UserData) ->
    Options = #options{
        threshold = ?LLSN_DEFAULT_THRESHOLD,
        framesize = ?LLSN_DEFAULT_FRAME_SIZE,
        frame = 1,
        binsize = 0,
        tail = [],
        stack = [],
        pid = PID,
        userdata = UserData,
        tt = typestree(new)
    },
    encode_ext(Packet, Struct, Options);

% framing and custom framelimit
encode(Packet, Struct, PID, FrameLimit) when is_pid(PID)
        and is_integer(FrameLimit)
        and is_tuple(Packet) and is_tuple(Struct) ->
    Options = #options{
        threshold = ?LLSN_DEFAULT_THRESHOLD,
        framesize = FrameLimit,
        frame = 1,
        binsize = 0,
        tail = [],
        stack = [],
        pid = PID,
        tt = typestree(new)
    },
    encode_ext(Packet, Struct, Options).

% framing and custom framelimit
encode(Packet, Struct, PID, FrameLimit, UserData) when is_pid(PID)
        and is_integer(FrameLimit) and is_tuple(Packet) 
        and is_tuple(Struct) and is_list(UserData)->
    Options = #options{
        threshold = ?LLSN_DEFAULT_THRESHOLD,
        framesize = FrameLimit,
        frame = 1,
        binsize = 0,
        tail = [],
        stack = [],
        pid = PID,
        userdata = UserData, % using on encoding frames to help identify by PID
        tt = typestree(new)
    },
    encode_ext(Packet, Struct, Options).


encode_ext(Packet, Struct, #options{threshold = Threshold} = Options) ->

    P   = tuple_to_list(Packet),
    Len = length(P),
    {LenBin, LenBinLen} = encode_UNUMBER(Len),
    Bin = <<Threshold:16/big-integer, LenBin/binary>>,

    Opts = #options{
            framesize    = 2 + LenBinLen, % first 2 bytes for threshold + N bytes for the number of elements
            struct       = Struct
            },
    

    encode_struct(P, tuple_to_list(Struct), Bin, Opts).

framing(Bin, #options{framesize    = FrameSize,
                frame  = FrameNumber,
                pid          = PID,
                userdata = UserData} = Opts, Value, ValueLen)
        when is_pid(PID), FrameSize + ValueLen >= ?LLSN_DEFAULT_FRAME_SIZE  ->
    Space = ?LLSN_DEFAULT_FRAME_SIZE - FrameSize,
    <<ValueHead:Space/binary-unit:8, ValueTail/binary>> = Value,
    Frame = <<Bin/binary, ValueHead/binary>>,
    % send it to the PID
    erlang:send(
        PID,
        {frame, FrameNumber, FrameSize + Space, Frame, UserData}
        ),
    % process tail to the new frame
    framing(<<>>, Opts#options{framesize   = 0,
                             frame = FrameNumber + 1 },
            ValueTail, ValueLen - Space);
framing(Bin, Opts, Value, ValueLen) ->
    { <<Bin/binary, Value/binary>>, Opts#options{framesize = Opts#options.framesize + ValueLen} }.




encode_struct(Value, Struct, Bin, Options) ->
    ok.








encode_NUMBER(Value) when 0 > Value ->
    NValue = Value * -1,
    encode_number(Value, NValue);

encode_NUMBER(Value) ->
    encode_number(Value, Value).

% 2^7 - 1
encode_number(Value, NValue) when NValue band 16#3f == NValue ->
    { <<16#0:1/big-unsigned-integer,Value:7/big-signed-integer>>, 1 };

% 2^14 -1
encode_number(Value, NValue) when NValue band 16#1fff == NValue ->
    { <<16#2:2/big-unsigned-integer,Value:14/big-signed-integer>>, 2 };

% 2^21 -1
encode_number(Value, NValue) when NValue band 16#fffff == NValue ->
    { <<16#6:3/big-unsigned-integer,Value:21/big-signed-integer>>, 3 };

% 2^28 -1
encode_number(Value, NValue) when NValue band 16#7ffffff == NValue ->
    { <<16#e:4/big-unsigned-integer,Value:28/big-signed-integer>>, 4};

% 2^35 -1
encode_number(Value, NValue) when NValue band 16#3ffffffff == NValue ->
    { <<16#1e:5/big-unsigned-integer,Value:35/big-signed-integer>>, 5 };

% 2^42 -1
encode_number(Value, NValue) when NValue band 16#1ffffffffff == NValue ->
    { <<16#3e:6/big-unsigned-integer,Value:42/big-signed-integer>>, 6 };

% 2^49 -1
encode_number(Value, NValue) when NValue band 16#ffffffffffff == NValue ->
    { <<16#7e:7/big-unsigned-integer,Value:49/big-signed-integer>>, 7 };

% 2^56 -1
encode_number(Value, NValue) when NValue band 16#7fffffffffffff == NValue ->
    { <<16#fe:8/big-unsigned-integer,Value:56/big-signed-integer>>, 8 };

% def
encode_number(Value, NValue) ->
    { <<16#ff:8/big-unsigned-integer,Value:64/big-signed-integer>>, 9 }.

% 2^7 - 1
encode_UNUMBER(Value) when Value band 16#7f == Value ->
    { <<16#0:1/big-unsigned-integer,Value:7/big-unsigned-integer>>, 1 };

% 2^14 -1
encode_UNUMBER(Value) when Value band 16#3fff == Value ->
    { <<16#2:2/big-unsigned-integer,Value:14/big-unsigned-integer>>, 2 };

% 2^21 -1
encode_UNUMBER(Value) when Value band 16#1fffff == Value ->
    { <<16#6:3/big-unsigned-integer,Value:21/big-unsigned-integer>>, 3 };

% 2^28 -1
encode_UNUMBER(Value) when Value band 16#fffffff == Value ->
    { <<16#e:4/big-unsigned-integer,Value:28/big-unsigned-integer>>, 4};

% 2^35 -1
encode_UNUMBER(Value) when Value band 16#7ffffffff == Value ->
    { <<16#1e:5/big-unsigned-integer,Value:35/big-unsigned-integer>>, 5 };

% 2^42 -1
encode_UNUMBER(Value) when Value band 16#3ffffffffff == Value ->
    { <<16#3e:6/big-unsigned-integer,Value:42/big-unsigned-integer>>, 6 };

% 2^49 -1
encode_UNUMBER(Value) when Value band 16#1ffffffffffff == Value ->
    { <<16#7e:7/big-unsigned-integer,Value:49/big-unsigned-integer>>, 7 };

% 2^56 -1
encode_UNUMBER(Value) when Value band 16#ffffffffffffff == Value ->
    { <<16#fe:8/big-unsigned-integer,Value:56/big-unsigned-integer>>, 8 };

% def
encode_UNUMBER(Value) ->
    { <<16#ff:8/big-unsigned-integer,Value:64/big-unsigned-integer>>, 9 }.


encode_float(Value, N, Pow) ->
    V  = Value * Pow,
    TV = trunc(V),
    if TV == V ->
            {N, TV};
        true ->
            encode_float(Value, N+1, Pow*10)
    end.

encode_FLOAT(Value) ->
    {P,M}    = encode_float(Value, 1, 10),
    {BP, PL} = encode_UNUMBER(P),
    {BM, ML} = encode_NUMBER(M),
    {<<BP/binary,BM/binary>>, PL+ML}.


% get GMT offset
% calendar:time_difference(calendar:universal_time(), calendar:local_time()).
% {0,{4,0,0}}

encode_DATE({{Year, Month, Day},
                {Hour, Min, Sec, MSec},
                {OffsetHour, OffsetMin}} = Date) ->
    {<<Year:16/big-integer,
            Month:4/big-unsigned-integer,
            Day:5/big-unsigned-integer,
            Hour:5/big-unsigned-integer,
            Min:6/big-unsigned-integer,
            Sec:6/big-unsigned-integer,
            MSec:10/big-unsigned-integer,
            OffsetHour:6/big-integer,
            OffsetMin:6/big-unsigned-integer>>, 8}.

encode_BOOL(true) -> {<<1:8/big-unsigned-integer>>, 1};
encode_BOOL(_)    -> {<<0:8/big-unsigned-integer>>, 1}.


%% =============================================================================
%% Decoding
%% =============================================================================
decode(<<V:4/big-unsigned-integer, Threshold:12/big-unsigned-integer, 
                Data1/binary>>) ->
    case decode_UNUMBER(Data1) of
        {parted, _} ->
            {parted, {Data1}};
        {N, Data} ->
            Opts = #dopts{threshold = Threshold,
                    stack     = [],
                    tail      = [],
                    find      = ?LLSN_NULL,
                    tt        = typestree NEW},
            decode_struct([], Data, N, Opts)
    end.

%% =============================================================================
%% Numbers
%% =============================================================================
decode_NUMBER_DEBUG(<<Num:64/big-signed-integer, DataTail/binary>>) ->
    {Num, DataTail};
decode_NUMBER_DEBUG(Data) ->
    {parted, Data}.

% decode number tab:
% 1111 1111   [.... 8 байт ....]           - 64 битное
% 1111 1110   [.... 7 байт ....]           - 56 битное
% 1111 110 .  [1 бит  + .... 6 байт ....]  - 49 битное
% 1111 10 ..  [2 бита + .... 5 байт ....]  - 42 битное
% 1111 0 ...  [3 бита + .... 4 байта ....] - 35 битное
% 1110  ....  [4 бита + .... 3 байта ....] - 28 битное
% 110.  ....  [5 бит  + .... 2 байта ....] - 21 битное
% 10..  ....  [6 бит  + .... 1 байт ....]  - 14 битное
% 0...  ....  [7 бит]                      - 7 битное число
decode_NUMBER(Data) ->
    % decode signed number
    decode_NUMBER(signed, Data).

decode_UNUMBER(Data) ->
    % decode unsigned number
    decode_NUMBER(unsigned, Data).

decode_NUMBER(unsigned, <<2#0:1/big-unsigned-integer,        Num:7/big-unsigned-integer,  Tail/binary>>) -> {Num, Tail};
decode_NUMBER(signed,   <<2#0:1/big-unsigned-integer,        Num:7/big-signed-integer,    Tail/binary>>) -> {Num, Tail};

decode_NUMBER(unsigned, <<2#10:2/big-unsigned-integer,       Num:14/big-unsigned-integer, Tail/binary>>) -> {Num, Tail};
decode_NUMBER(signed,   <<2#10:2/big-unsigned-integer,       Num:14/big-signed-integer,   Tail/binary>>) -> {Num, Tail};

decode_NUMBER(unsigned, <<2#110:3/big-unsigned-integer,      Num:21/big-unsigned-integer, Tail/binary>>) -> {Num, Tail};
decode_NUMBER(signed,   <<2#110:3/big-unsigned-integer,      Num:21/big-signed-integer,   Tail/binary>>) -> {Num, Tail};

decode_NUMBER(unsigned, <<2#1110:4/big-unsigned-integer,     Num:28/big-unsigned-integer, Tail/binary>>) -> {Num, Tail};
decode_NUMBER(signed,   <<2#1110:4/big-unsigned-integer,     Num:28/big-signed-integer,   Tail/binary>>) -> {Num, Tail};

decode_NUMBER(unsigned, <<2#11110:5/big-unsigned-integer,    Num:35/big-unsigned-integer, Tail/binary>>) -> {Num, Tail};
decode_NUMBER(signed,   <<2#11110:5/big-unsigned-integer,    Num:35/big-signed-integer,   Tail/binary>>) -> {Num, Tail};

decode_NUMBER(unsigned, <<2#111110:6/big-unsigned-integer,   Num:42/big-unsigned-integer, Tail/binary>>) -> {Num, Tail};
decode_NUMBER(signed,   <<2#111110:6/big-unsigned-integer,   Num:42/big-signed-integer,   Tail/binary>>) -> {Num, Tail};

decode_NUMBER(unsigned, <<2#1111110:7/big-unsigned-integer,  Num:49/big-unsigned-integer, Tail/binary>>) -> {Num, Tail};
decode_NUMBER(signed,   <<2#1111110:7/big-unsigned-integer,  Num:49/big-signed-integer,   Tail/binary>>) -> {Num, Tail};

decode_NUMBER(unsigned, <<2#11111110:8/big-unsigned-integer, Num:56/big-unsigned-integer, Tail/binary>>) -> {Num, Tail};
decode_NUMBER(signed,   <<2#11111110:8/big-unsigned-integer, Num:56/big-signed-integer,   Tail/binary>>) -> {Num, Tail};

decode_NUMBER(unsigned, <<2#11111111:8/big-unsigned-integer, Num:64/big-unsigned-integer, Tail/binary>>) -> {Num, Tail};
decode_NUMBER(signed,   <<2#11111111:8/big-unsigned-integer, Num:64/big-signed-integer,   Tail/binary>>) -> {Num, Tail};

decode_NUMBER(_,   Data) -> {parted, Data}.

%% =============================================================================
%% Floats
%% =============================================================================
% decode_FLOAT(<<Float:64/big-float, Tail/binary>>) -> {Float, Tail};
% decode_FLOAT(Data)                                -> {parted, Data}.


decode_FLOAT(Data) ->
    case decode_UNUMBER(Data) of
        {parted, _} ->
            {parted, Data};
        {Pow, Tail1} ->
            case decode_NUMBER(Tail1) of
                {parted, _} ->
                    {parted, Data};
                {N, Tail2} ->
                    {N/(math:pow(10,Pow)), Tail2}
            end
    end.

%% =============================================================================
%% Strings
%% =============================================================================
decode_STRING(Data, Opts) ->
    case decode_UNUMBER(Data) of
        {parted, _}     ->
            {parted, Data, Opts};
        {Len, DataTail} ->
            if Len > Opts#dopts.threshold, Opts#dopts.threshold > 0 ->
                    Opts1 = Opts#dopts{tail = lists:append(Opts#dopts.tail, [ {string, Len} ])},
                    {tail, DataTail, Opts1};
                true ->
                    case DataTail of
                        <<BinStrValue:Len/binary-unit:8, DataTail1/binary>> ->
                            StrValue = unicode:characters_to_list(BinStrValue, utf8),
                            {StrValue, DataTail1, Opts};
                        _ ->
                            {parted, Data, Opts}
                    end
            end
    end.

%% =============================================================================
%% Blobs
%% =============================================================================
decode_BLOB(Data, Opts) ->
    case decode_UNUMBER(Data) of
        {parted, _} ->
            {parted, Data, Opts};
        {Len, DataTail} ->
            if Len > Opts#dopts.threshold, Opts#dopts.threshold > 0 ->
                    Opts1 = Opts#dopts{tail = lists:append(Opts#dopts.tail, [ {blob, Len} ])},
                    {tail, DataTail, Opts1};
                true ->
                    case DataTail of
                        <<Value:Len/binary-unit:8, DataTail1/binary>> ->
                            {Value, DataTail1, Opts};
                        _ ->
                            {parted, Data, Opts}
                    end
            end
    end.

%% =============================================================================
%% Files
%% =============================================================================
% FIXME
decode_FILE(Data, Opts) ->
    {file, Data, Opts}.


%% =============================================================================
%% Dates
%% =============================================================================
% 2B: year. (-32767..32768), знак определяет эпоху AC/BC
%   :4b month (1..12)
%   :5b day of month (1..31)
%   :5b hour (0..23)
%   :6b min (0..59)
%   :6b sec (0..59)
%   :10 msec (0..999)
%   :6b hours offset (signed)
%   :6b min offset (unsigned)
%   -- :48bit
% --
% 8B total
decode_DATE(<<Year:16/big-signed-integer,
                Month:4/big-unsigned-integer,
                Day:5/big-unsigned-integer,
                Hour:5/big-unsigned-integer,
                Min:6/big-unsigned-integer,
                Sec:6/big-unsigned-integer,
                MSec:10/big-unsigned-integer,
                OffsetHour:6/big-integer,
                OffsetMin:6/big-unsigned-integer, DataTail/binary>>) ->
    {{{Year, Month, Day}, {Hour, Min, Sec, MSec}, {OffsetHour, OffsetMin}}, 
     DataTail};
decode_DATE(Data) ->
    {parted, Data}.

%% =============================================================================
%% Booleans
%% =============================================================================
decode_BOOL(<<0:8/big-unsigned-integer, DataTail/binary>>) -> {false, DataTail};
decode_BOOL(<<1:8/big-unsigned-integer, DataTail/binary>>) -> {true, DataTail};
decode_BOOL(Data)                                          -> {parted, Data}.



%% =============================================================================
%% Booleans
%% =============================================================================

typesTree(new) ->
    #typestree{
        type     = ?LLSN_NULL,
        length   = ?LLSN_NULL,
        
        child    = ?LLSN_NULL,
        parent   = ?LLSN_NULL,
        prev     = ?LLSN_NULL,
        next     = ?LLSN_NULL,
        
        nullflag = ?LLSN_NULL}.

typesTree(next, Current) ->
    case Current#typestree.next of
        ?LLSN_NULL ->
            TT = typesTree(new),
            TT#typestree{
                prev     = Current,
                parent   = Current#typestree.parent,
                nullflag = Current#typestree.nullflag};
        TT ->
            TT#typestree{
                prev     = Current,
                parent   = Current#typestree.parent,
                nullflag = Current#typestree.nullflag};
    end;

typesTree(child, Parent) ->
    case Current#typestree.child of
        ?LLSN_NULL ->
            TT = typesTree(new),
            TT#typestree{
                parent   = Current,
                nullflag = Current#typestree.nullflag};
        TT ->
            TT#typestree{
                parent   = Current,
                nullflag = Current#typestree.nullflag};
    end;

typesTree(Mode, Current, Type) ->
    typesTree(Mode, Current#typestree{type = Type});
 
typesTree(Mode, Current, Type, Len) ->
    typesTree(Mode, Current#typestree{type = Type, length = Len});