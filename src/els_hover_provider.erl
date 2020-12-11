-module(els_hover_provider).

-behaviour(els_provider).

-export([ handle_request/2
        , is_enabled/0
        ]).

%%==============================================================================
%% Includes
%%==============================================================================
-include("erlang_ls.hrl").

-ifdef(OTP_RELEASE).
-if(?OTP_RELEASE >= 23).
-include_lib("kernel/include/eep48.hrl").
-endif.
-endif.

%%==============================================================================
%% Types
%%==============================================================================
-type state() :: any().

%%==============================================================================
%% Dialyer Ignores (due to upstream bug, see ERL-1262
%%==============================================================================
-dialyzer({nowarn_function, get_docs/3}).

%%==============================================================================
%% els_provider functions
%%==============================================================================

-spec is_enabled() -> boolean().
is_enabled() ->
  true.

-spec handle_request(any(), state()) -> {any(), state()}.
handle_request({hover, Params}, State) ->
  #{ <<"position">>     := #{ <<"line">>      := Line
                            , <<"character">> := Character
                            }
   , <<"textDocument">> := #{<<"uri">> := Uri}
   } = Params,
  case documentation(Uri, Line, Character) of
    <<>> ->
      {null, State};
    Doc ->
      {#{contents => Doc}, State}
  end.

-spec documentation(uri(), non_neg_integer(), non_neg_integer()) -> binary().
documentation(Uri, Line, Character) ->
  {ok, Document} = els_utils:lookup_document(Uri),
  case els_dt_document:get_element_at_pos(Document, Line + 1, Character + 1)
  of
    [POI|_] -> documentation(els_uri:module(Uri), POI);
    []      -> <<>>
  end.

%% @doc docs for documentation
-spec documentation(atom(), poi()) -> binary().
documentation(_M, #{kind := application, id := {M, F, A}}) ->
  get_docs(M, F, A);
documentation(_M, #{kind := type_application, id := {M, F, A}}) ->
  get_type_docs(M, F, A);
documentation(M, #{kind := type_application, id := {F, A}}) ->
  get_type_docs(M, F, A);
documentation(M, #{kind := application, id := {F, A}}) ->
  get_docs(M, F, A);
documentation(M, #{kind := export_entry, id := {F, A}}) ->
  get_docs(M, F, A);
documentation(_M, _POI) ->
  <<>>.

%% @doc get the docs
%%
%% Uses code:get_doc/1 if available and docs are available
%% otherwise uses the source files to gather the documentation
%%
-spec get_docs(atom(), atom(), byte()) -> binary().
-spec get_type_docs(atom(), atom(), byte()) -> binary().
-ifdef(OTP_RELEASE).
-if(?OTP_RELEASE >= 23).
get_docs(M, F, A) ->
  Kind = content_kind(),
  try get_doc_chunk(M) of
    {ok, #docs_v1{ format = ?NATIVE_FORMAT
                 , module_doc = MDoc
                 } = DocChunk} when MDoc =/= none ->
      case shell_docs:render(M, F, A, DocChunk, #{ type => markdown }) of
          {error, _} ->
              case shell_docs:render(M, F, DocChunk, #{ type => markdown }) of
                  {error, _} ->
                      docs_from_src(M, F, A);
                  FuncDoc ->
                      #{ kind => Kind
                       , value => els_utils:to_binary(FuncDoc)
                       }
              end;
        FuncDoc ->
          #{ kind => Kind
           , value => els_utils:to_binary(FuncDoc)
           }
      end;
    _R1 ->
      docs_from_src(M, F, A)
  catch C:E:ST ->
      %% code:get_doc/1 fails for escriptized modules, so fall back
      %% reading docs from source. See #751 for details
      Fmt = "Error fetching docs, falling back to src."
        " module=~p error=~p:~p st=~p",
      Args = [M, C, E, ST],
      lager:warning(Fmt, Args),
      docs_from_src(M, F, A)
  end.

get_type_docs(M, F, A) ->
    Kind = content_kind(),
    try get_doc_chunk(M) of
        {ok, #docs_v1{ format = ?NATIVE_FORMAT
                     , module_doc = MDoc
                     } = DocChunk} when MDoc =/= none ->
            case shell_docs:render_type(M, F, A, DocChunk, #{ type => markdown }) of
                {error, _} ->
                    case shell_docs:render_type(M, F, DocChunk, #{ type => markdown }) of
                        {error, _} ->
                            <<>>;
                        FuncDoc ->
                            #{ kind => Kind
                             , value => els_utils:to_binary(FuncDoc)
                             }
                    end;
                FuncDoc ->
                    #{ kind => Kind
                     , value => els_utils:to_binary(FuncDoc)
                     }
            end;
        _R1 ->
            <<>>
    catch C:E:ST ->
            %% code:get_doc/1 fails for escriptized modules, so fall back
            %% reading docs from source. See #751 for details
            Fmt = "Error fetching docs, falling back to src."
                " module=~p error=~p:~p st=~p",
            Args = [M, C, E, ST],
            lager:warning(Fmt, Args),
            <<>>
    end.

%% This function first tries to read the doc chunk from the .beam file
%% and if that fails it attempts to find the .chunk file.
-spec get_doc_chunk(M :: module()) -> {ok, term()} | error.
get_doc_chunk(M) ->
  {ok, Uri} = els_utils:find_module(M),
  SrcDir    = filename:dirname(els_utils:to_list(els_uri:path(Uri))),
  BeamFile  = filename:join([SrcDir, "..", "ebin", lists:concat([M, ".beam"])]),
  ChunkFile = filename:join([SrcDir, "..", "doc", "chunks",
                             lists:concat([M, ".chunk"])]),
  case beam_lib:chunks(BeamFile, ["Docs"]) of
    {ok, {_Mod, [{"Docs", Bin}]}} ->
        {ok, binary_to_term(Bin)};
    _ ->
      case file:read_file(ChunkFile) of
        {ok, Bin} ->
          {ok, binary_to_term(Bin)};
        _ ->
          error
      end
  end.
-else.
get_docs(M, F, A) ->
  docs_from_src(M, F, A).
get_type_docs(_M, _F, _A) ->
  <<>>.
-endif.
-endif.

%%==============================================================================
%% Internal functions
%%==============================================================================

-spec docs_from_src(atom(), atom(), byte()) -> binary().
docs_from_src(M, F, A) ->
  case {specs(M, F, A), edoc(M, F, A)} of
    {<<>>, <<>>} ->
      <<>>;
    {Specs, Edoc} ->
      ContentKind = content_kind(),
      FormattedSpecs = format_code(ContentKind, Specs),
      #{ kind  => ContentKind
       , value => << FormattedSpecs/binary, "\n", Edoc/binary>>
       }
  end.

-spec specs(atom(), atom(), non_neg_integer()) -> binary().
specs(M, F, A) ->
  case els_dt_signatures:lookup({M, F, A}) of
    {ok, [#{spec := Spec}]} ->
      Spec;
    {ok, []} ->
      <<>>
  end.

-spec format_code(markup_kind(), binary()) -> binary().
format_code(plaintext, Code) ->
  Code;
format_code(markdown, Code) ->
  <<"```erlang\n", Code/binary, "\n```\n">>.

-spec edoc(atom(), atom(), non_neg_integer()) -> binary().
edoc(M, F, A) ->
  try
    {ok, Uri} = els_utils:find_module(M),
    Path      = els_uri:path(Uri),
    {M, EDoc} = edoc:get_doc( els_utils:to_list(Path)
                            , [{private, true}]
                            ),
    Internal  = xmerl:export_simple([EDoc], docsh_edoc_xmerl),
    %% TODO: Something is weird with the docsh specs.
    %%       For now, let's avoid the Dialyzer warnings.
    Docs = erlang:apply(docsh_docs_v1, from_internal, [Internal]),
    Res  = erlang:apply(docsh_docs_v1, lookup, [ Docs
                                               , {M, F, A}
                                               , [doc, spec]]),
    {ok, [{{function, F, A}, _Anno, Signature, Desc, _Metadata}|_]} = Res,
    format(Signature, Desc)
  catch C:E ->
      lager:error("[hover] Error fetching edoc [error=~p]", [{C, E}]),
      <<>>
  end.

-spec format(binary(), none | map()) -> binary().
format(_Signature, none) ->
  <<>>;
format(Signature, Desc) when is_map(Desc) ->
  Lang         = <<"en">>,
  Doc          = maps:get(Lang, Desc, <<>>),
  FormattedDoc = els_utils:to_binary(docsh_edoc:format_edoc(Doc, #{})),
  <<"### ", Signature/binary, "\n", FormattedDoc/binary>>.

-spec content_kind() -> markup_kind().
content_kind() ->
  ContentFormat =
    case els_config:get(capabilities) of
      #{<<"textDocument">> := #{<<"hover">> := #{<<"contentFormat">> := X}}} ->
        X;
      _ ->
        []
    end,
  case lists:member(atom_to_binary(?MARKDOWN, utf8), ContentFormat) of
    true  -> ?MARKDOWN;
    false -> ?PLAINTEXT
  end.
