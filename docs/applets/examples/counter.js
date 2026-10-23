/* orbit-applet
{"id":"counter","name":"Counter","domains":[]}
*/
module.exports = {
  action(ctx, event) {
    if (event.action === 'add') ctx.storage.set('n', ctx.storage.get('n', 0) + 1);
  },
  render(ctx) {
    return {type:'vstack', spacing:16, children:[
      {type:'text', text:'Count: '+ctx.storage.get('n',0), size:32},
      {type:'button', text:'Add one', action:'add'}
    ]};
  }
};
