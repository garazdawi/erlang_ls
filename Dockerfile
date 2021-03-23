FROM erlang:23

RUN apt-get update -y && apt-get install vim make curl git nodejs -y 

RUN git clone https://github.com/garazdawi/erlang_ls/
RUN git clone https://github.com/josefs/Gradualizer

RUN cd Gradualizer && make
RUN cd erlang_ls && git checkout gradualizer && make
ENV ERL_FLAGS="-pa /Gradualizer/ebin"

RUN curl -fLo ~/.vim/autoload/plug.vim --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

RUN echo   "call plug#begin('~/.vim/plugged')\n\
Plug 'neoclide/coc.nvim', {'branch': 'release'}\n\
call plug#end()" >> /root/.vimrc

RUN vim +PlugInstall +qall

RUN echo \
'{\n\
  "languageserver": {\n\
   "erlang": {\n\
    "command": "/erlang_ls/_build/default/bin/erlang_ls",\n\
      "filetypes": ["erlang"]\n\
    }\n\
  }\n\
}' >> /root/.vim/coc-settings.json
 
