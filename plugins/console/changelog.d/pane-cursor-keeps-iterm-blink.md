bump: patch

- A terminal pane with an iTerm profile keeps the cursor blink the profile sets when the shell
  sends mode 12 (`CSI ? 12 l` or `h`), as iTerm does; other modes in the same sequence still apply.
