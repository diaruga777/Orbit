/* orbit-applet
{"id":"release-watch","name":"Release Watch","domains":["api.github.com"],"pollHours":6,"notifications":true}
*/
// Change cli/cli to the public GitHub repository you want to follow.
module.exports = {
  async poll(ctx) {
    const response = await fetch('https://api.github.com/repos/cli/cli/releases/latest', {
      headers: {'Accept':'application/vnd.github+json'}
    });
    if (!response.ok) throw new Error('GitHub returned ' + response.status);
    const release = await response.json();
    if (typeof release.tag_name !== 'string' || !release.tag_name ||
        !Number.isSafeInteger(release.id)) throw new Error('Unexpected release data');
    const previous = ctx.storage.get('releaseID');
    if (previous !== null && previous !== release.id) {
      ctx.notify({id:String(release.id),title:'New GitHub CLI release',body:release.tag_name});
    }
    ctx.storage.set('releaseID',release.id);
    ctx.storage.set('tag',release.tag_name);
    ctx.storage.set('checkedAt',ctx.now.toISOString());
  },
  render(ctx) {
    return {type:'vstack',spacing:12,children:[
      {type:'text',text:'GitHub CLI',size:28,weight:'bold'},
      {type:'text',text:ctx.storage.get('tag','Waiting for the first check')},
      {type:'text',text:'Checked: ' + ctx.storage.get('checkedAt','Not yet'),color:'secondary'}
    ]};
  }
};
