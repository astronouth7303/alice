//= require <prototype>
//= require <effects>
//= require <dragdrop>
//= require <shortcut>

var Alice = { };

//= require <alice/util>
//= require <alice/application>
//= require <alice/connection>
//= require <alice/window>
//= require <alice/input>
//= require <alice/keyboard>

var alice = new Alice.Application();

document.observe("dom:loaded", function () {
  $$("div.topic").each(function (topic){
    topic.innerHTML = Alice.makeLinksClickable(topic.innerHTML)});
  $('config_button').observe("click", alice.toggleConfig.bind(alice));
  alice.activeWindow().input.focus()
  window.onkeydown = function () {
    if (!$('config') && !alice.isCtrl && !alice.isCommand && !alice.isAlt)
      alice.activeWindow().input.focus()};
  window.onresize = function () {
    alice.activeWindow().scrollToBottom()};
  window.status = " ";  
  window.onfocus = function () {
    alice.activeWindow().input.focus();
    alice.isFocused = true};
  window.onblur = function () {alice.isFocused = false};
  Alice.makeSortable();
});
