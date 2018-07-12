function sendTestNotification(user_id, home_ou, event_def_type, authtoken) {
    var hook = 'au.' + event_def_type + '.test';
    
    var args = {
        target: user_id,
        home_ou: home_ou,
        event_def_type: hook
    };
    
    new OpenSRF.ClientSession('open-ils.actor').request({
        method: 'open-ils.actor.event.test_notification',
        params: [authtoken, args],
        oncomplete: function(r) {
            var resp = r.recv();
            if (resp) {
                var banner = document.getElementById('test_notification_banner');
                banner.style.display = 'table-row';
            }
        }
    }).send();
}