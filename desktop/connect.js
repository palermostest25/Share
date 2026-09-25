const form = document.querySelector('#connect');
form.addEventListener('submit', async event => {
  event.preventDefault();
  const button = form.querySelector('button');
  button.disabled = true;
  document.querySelector('#error').textContent = '';
  const result = await window.shareDesktop.connect(document.querySelector('#server').value);
  if (result?.error) document.querySelector('#error').textContent = result.error;
  button.disabled = false;
});
