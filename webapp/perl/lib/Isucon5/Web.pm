package Isucon5::Web;

use strict;
use warnings;
use utf8;
use Kossy;
use DBIx::Sunny;
use Encode;
use Redis::Fast;
use Data::MessagePack;
use Digest::SHA qw/sha512_hex/;
use Isucon5::Users;

my $db;
sub db {
    $db ||= do {
        my %db = (
            host => $ENV{ISUCON5_DB_HOST} || 'localhost',
            port => $ENV{ISUCON5_DB_PORT} || 3306,
            username => $ENV{ISUCON5_DB_USER} || 'root',
            password => $ENV{ISUCON5_DB_PASSWORD},
            database => $ENV{ISUCON5_DB_NAME} || 'isucon5q',
        );
        DBIx::Sunny->connect(
            "dbi:mysql:database=$db{database};host=$db{host};port=$db{port}", $db{username}, $db{password}, {
                RaiseError => 1,
                PrintError => 0,
                AutoInactiveDestroy => 1,
                mysql_enable_utf8   => 1,
                mysql_auto_reconnect => 1,
            },
        );
    };
}

my $redis;
sub redis {
    $redis ||= do {
        Redis::Fast->new(
            encoding  => undef,
            reconnect => 5,
            every     => 200,
        );
    };
}

my $mp;
sub mp { $mp ||= Data::MessagePack->new()->utf8; }

my ($SELF, $C);
sub session {
    $C->stash->{session};
}

sub stash {
    $C->stash;
}

sub redirect {
    $C->redirect(@_);
}

sub abort_authentication_error {
    session()->{user_id} = undef;
    $C->halt(401, encode_utf8($C->tx->render('login.tx', { message => 'ログインに失敗しました' })));
}

sub abort_permission_denied {
    $C->halt(403, encode_utf8($C->tx->render('error.tx', { message => '友人のみしかアクセスできません' })));
}

sub abort_content_not_found {
    $C->halt(404, encode_utf8($C->tx->render('error.tx', { message => '要求されたコンテンツは存在しません' })));
}

sub authenticate {
    my ($email, $password) = @_;
    my $query = <<SQL;
SELECT u.id AS id, u.account_name AS account_name, u.nick_name AS nick_name, u.email AS email,
s.salt AS salt, u.passhash AS hash FROM users u
JOIN salts s ON u.id = s.user_id
WHERE u.email = ?;
SQL
    my $result = db->select_row($query, $email);
    if (!$result || sha512_hex($password.$result->{salt}) ne $result->{hash}) {
        abort_authentication_error();
    }
    session()->{user_id} = $result->{id};
    return $result;
}

sub current_user {
    my ($self, $c) = @_;
    my $user = stash()->{user};

    return $user if ($user);

    return undef if (!session()->{user_id});

    my $user_id = session()->{user_id};
    $user = $Isucon5::Users::USERS->{$user_id} || db->select_row('SELECT id, account_name, nick_name, email FROM users WHERE id=?', session()->{user_id});
    if (!$user) {
        session()->{user_id} = undef;
        abort_authentication_error();
    }
    return $user;
}

sub get_user {
    my ($user_id) = @_;
    my $user = $Isucon5::Users::USERS->{$user_id} || db->select_row('SELECT * FROM users WHERE id = ?', $user_id);
    abort_content_not_found() if (!$user);
    return $user;
}

sub user_from_account {
    my ($account_name) = @_;
    my $user = $Isucon5::Users::USER_ACCOUNT_NAME_MAP->{$account_name} || db->select_row('SELECT * FROM users WHERE account_name = ?', $account_name);
    abort_content_not_found() if (!$user);
    return $user;
}

sub is_friend {
    my ($another_id) = @_;
    my $user_id = session()->{user_id};
    my $query = 'SELECT id FROM relations WHERE one = ? AND another = ?';
    my $exists = db->select_one($query, $user_id, $another_id);
    return $exists ? 1 : 0;
}

sub is_friend_account {
    my ($account_name) = @_;
    is_friend(user_from_account($account_name)->{id});
}

sub mark_footprint {
    my ($user_id) = @_;
    if ($user_id != current_user()->{id}) {
        my $query = 'INSERT INTO footprints (user_id,owner_id) VALUES (?,?)';
        db->query($query, $user_id, current_user()->{id});
    }
}

sub permitted {
    my ($another_id) = @_;
    $another_id == current_user()->{id} || is_friend($another_id);
}

my $PREFS;
sub prefectures {
    $PREFS ||= do {
        [
        '未入力',
        '北海道', '青森県', '岩手県', '宮城県', '秋田県', '山形県', '福島県', '茨城県', '栃木県', '群馬県', '埼玉県', '千葉県', '東京都', '神奈川県', '新潟県', '富山県',
        '石川県', '福井県', '山梨県', '長野県', '岐阜県', '静岡県', '愛知県', '三重県', '滋賀県', '京都府', '大阪府', '兵庫県', '奈良県', '和歌山県', '鳥取県', '島根県',
        '岡山県', '広島県', '山口県', '徳島県', '香川県', '愛媛県', '高知県', '福岡県', '佐賀県', '長崎県', '熊本県', '大分県', '宮崎県', '鹿児島県', '沖縄県'
        ]
    };
}

filter 'authenticated' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        if (!current_user()) {
            return redirect('/login');
        }
        $app->($self, $c);
    }
};

filter 'set_global' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        $SELF = $self;
        $C = $c;
        $C->stash->{session} = $c->req->env->{"psgix.session"};
        $app->($self, $c);
    }
};

get '/login' => sub {
    my ($self, $c) = @_;
    $c->render('login.tx', { message => '高負荷に耐えられるSNSコミュニティサイトへようこそ!' });
};

post '/login' => [qw(set_global)] => sub {
    my ($self, $c) = @_;
    my $email = $c->req->param("email");
    my $password = $c->req->param("password");
    authenticate($email, $password);
    redirect('/');
};

get '/logout' => [qw(set_global)] => sub {
    my ($self, $c) = @_;
    session()->{user_id} = undef;
    redirect('/login');
};

get '/' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $current_user_id = current_user()->{id};
    my $all_friends = get_friends(current_user()->{id});
    my $friends_placeholder = join ',', ( ('?') x scalar @$all_friends );

    my $profile = db->select_row('SELECT * FROM profiles WHERE user_id = ?', current_user()->{id});

    my $entries_query = 'SELECT * FROM entries WHERE user_id = ? ORDER BY id LIMIT 5';
    my $entries = [];
    for my $entry (@{db->select_all($entries_query, current_user()->{id})}) {
        $entry->{is_private} = ($entry->{private} == 1);
        my ($title, $content) = split(/\n/, $entry->{body}, 2);
        $entry->{title} = $title;
        $entry->{content} = $content;
        push @$entries, $entry;
    }

    my $comments_for_me_query = <<SQL;
SELECT c.id AS id, c.entry_id AS entry_id, c.user_id AS user_id, c.comment AS comment, c.created_at AS created_at
FROM comments c
JOIN entries e ON c.entry_id = e.id
WHERE e.user_id = ?
ORDER BY c.id DESC
LIMIT 10
SQL
    my $comments_for_me = [];
    my $comments = [];
    for my $comment (@{db->select_all($comments_for_me_query, current_user()->{id})}) {
        my $comment_user = get_user($comment->{user_id});
        $comment->{account_name} = $comment_user->{account_name};
        $comment->{nick_name} = $comment_user->{nick_name};
        push @$comments_for_me, $comment;
    }

    my $entries_of_friends = [map {mp->unpack($_)} redis->lrange("entries_of_friends:$current_user_id", 0, 9)];
    if (@$entries_of_friends == 0) {
        for my $entry (@{db->select_all("SELECT * FROM entries WHERE user_id IN ($friends_placeholder) ORDER BY id DESC LIMIT 10", @$all_friends)}) {
            my ($title) = split(/\n/, $entry->{body});
            $entry->{title} = $title;
            my $owner = get_user($entry->{user_id});
            $entry->{account_name} = $owner->{account_name};
            $entry->{nick_name} = $owner->{nick_name};
            push @$entries_of_friends, $entry;
            redis->rpush("entries_of_friends:$current_user_id", mp->pack($entry));
            last if @$entries_of_friends+0 >= 10;
        }
    }

    my $comments_of_friends = [map {mp->unpack($_)} redis->lrange("comments_of_friends:$current_user_id", 0, 9)];
    if (@$comments_of_friends == 0) {
        for my $comment (@{db->select_all("SELECT * FROM comments WHERE user_id IN ($friends_placeholder) ORDER BY id DESC LIMIT 1000", @$all_friends)}) {
            my $entry = db->select_row('SELECT * FROM entries WHERE id = ?', $comment->{entry_id});
            $entry->{is_private} = ($entry->{private} == 1);
            next if ($entry->{is_private} && !permitted($entry->{user_id}));
            my $entry_owner = get_user($entry->{user_id});
            $entry->{account_name} = $entry_owner->{account_name};
            $entry->{nick_name} = $entry_owner->{nick_name};
            $comment->{entry} = $entry;
            my $comment_owner = get_user($comment->{user_id});
            $comment->{account_name} = $comment_owner->{account_name};
            $comment->{nick_name} = $comment_owner->{nick_name};
            push @$comments_of_friends, $comment;
            redis->rpush("comments_of_friends:$current_user_id", mp->pack($comment));
            last if @$comments_of_friends+0 >= 10;
        }
    }

    my $friends_query = 'SELECT * FROM relations WHERE one = ? ORDER BY id DESC';
    my %friends = ();
    my $friends = [];
    for my $rel (@{db->select_all($friends_query, current_user()->{id}, current_user()->{id})}) {
        my $key = ($rel->{one} == current_user()->{id} ? 'another' : 'one');
        $friends{$rel->{$key}} ||= do {
            my $friend = get_user($rel->{$key});
            $rel->{account_name} = $friend->{account_name};
            $rel->{nick_name} = $friend->{nick_name};
            push @$friends, $rel;
            $rel;
        };
    }

    my $query = <<SQL;
SELECT f.user_id AS user_id, f.owner_id AS owner_id, u.account_name AS account_name, u.nick_name AS nick_name, DATE(created_at) AS date, MAX(created_at) as updated
FROM footprints f
JOIN users u ON u.id = f.owner_id
WHERE user_id = ?
GROUP BY user_id, owner_id, DATE(created_at)
ORDER BY updated DESC
LIMIT 10
SQL
    my $footprints = db->select_all($query, current_user()->{id});

    my $locals = {
        'user' => current_user(),
        'profile' => $profile,
        'entries' => $entries,
        'comments_for_me' => $comments_for_me,
        'entries_of_friends' => $entries_of_friends,
        'comments_of_friends' => $comments_of_friends,
        'friends' => $friends,
        'footprints' => $footprints
    };
    $c->render('index.tx', $locals);
};

get '/profile/:account_name' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $account_name = $c->args->{account_name};
    my $owner = user_from_account($account_name);
    my $prof = db->select_row('SELECT * FROM profiles WHERE user_id = ?', $owner->{id});
    $prof = {} if (!$prof);
    my $query;
    if (permitted($owner->{id})) {
        $query = 'SELECT * FROM entries WHERE user_id = ? ORDER BY created_at LIMIT 5';
    } else {
        $query = 'SELECT * FROM entries WHERE user_id = ? AND private=0 ORDER BY created_at LIMIT 5';
    }
    my $entries = [];
    for my $entry (@{db->select_all($query, $owner->{id})}) {
        $entry->{is_private} = ($entry->{private} == 1);
        my ($title, $content) = split(/\n/, $entry->{body}, 2);
        $entry->{title} = $title;
        $entry->{content} = $content;
        push @$entries, $entry;
    }
    mark_footprint($owner->{id});
    my $locals = {
        owner => $owner,
        profile => $prof,
        entries => $entries,
        private => permitted($owner->{id}),
        is_friend => is_friend($owner->{id}),
        current_user => current_user(),
        prefectures => prefectures(),
    };
    $c->render('profile.tx', $locals);
};

post '/profile/:account_name' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $account_name = $c->args->{account_name};
    if ($account_name ne current_user()->{account_name}) {
        abort_permission_denied();
    }
    my $first_name =  $c->req->param('first_name');
    my $last_name = $c->req->param('last_name');
    my $sex = $c->req->param('sex');
    my $birthday = $c->req->param('birthday');
    my $pref = $c->req->param('pref');

    my $prof = db->select_row('SELECT * FROM profiles WHERE user_id = ?', current_user()->{id});
    if ($prof) {
      my $query = <<SQL;
UPDATE profiles
SET first_name=?, last_name=?, sex=?, birthday=?, pref=?, updated_at=CURRENT_TIMESTAMP()
WHERE user_id = ?
SQL
        db->query($query, $first_name, $last_name, $sex, $birthday, $pref, current_user()->{id});
    } else {
        my $query = <<SQL;
INSERT INTO profiles (user_id,first_name,last_name,sex,birthday,pref) VALUES (?,?,?,?,?,?)
SQL
        db->query($query, current_user()->{id}, $first_name, $last_name, $sex, $birthday, $pref);
    }
    redirect('/profile/'.$account_name);
};

get '/diary/entries/:account_name' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $account_name = $c->args->{account_name};
    my $owner = user_from_account($account_name);
    my $query;
    if (permitted($owner->{id})) {
        $query = 'SELECT * FROM entries WHERE user_id = ? ORDER BY created_at DESC LIMIT 20';
    } else {
        $query = 'SELECT * FROM entries WHERE user_id = ? AND private=0 ORDER BY created_at DESC LIMIT 20';
    }
    my $entries = [];
    for my $entry (@{db->select_all($query, $owner->{id})}) {
        $entry->{is_private} = ($entry->{private} == 1);
        my ($title, $content) = split(/\n/, $entry->{body}, 2);
        $entry->{title} = $title;
        $entry->{content} = $content;
        $entry->{comment_count} = db->select_one('SELECT COUNT(*) AS c FROM comments WHERE entry_id = ?', $entry->{id});
        push @$entries, $entry;
    }
    mark_footprint($owner->{id});
    my $locals = {
        owner => $owner,
        entries => $entries,
        myself => (current_user()->{id} == $owner->{id}),
    };
    $c->render('entries.tx', $locals);
};

get '/diary/entry/:entry_id' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $entry_id = $c->args->{entry_id};
    my $entry = db->select_row('SELECT * FROM entries WHERE id = ?', $entry_id);
    abort_content_not_found() if (!$entry);
    my ($title, $content) = split(/\n/, $entry->{body}, 2);
    $entry->{title} = $title;
    $entry->{content} = $content;
    $entry->{is_private} = ($entry->{private} == 1);
    my $owner = get_user($entry->{user_id});
    if ($entry->{is_private} && !permitted($owner->{id})) {
        abort_permission_denied();
    }
    my $comments = [];
    for my $comment (@{db->select_all('SELECT * FROM comments WHERE entry_id = ?', $entry->{id})}) {
        my $comment_user = get_user($comment->{user_id});
        $comment->{account_name} = $comment_user->{account_name};
        $comment->{nick_name} = $comment_user->{nick_name};
        push @$comments, $comment;
    }
    mark_footprint($owner->{id});
    my $locals = {
        'owner' => $owner,
        'entry' => $entry,
        'comments' => $comments,
    };
    $c->render('entry.tx', $locals);
};

post '/diary/entry' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $query = 'INSERT INTO entries (user_id, private, body) VALUES (?,?,?)';
    my $title = $c->req->param('title');
    my $content = $c->req->param('content');
    my $private = $c->req->param('private');
    my $body = ($title || "タイトルなし") . "\n" . $content;
    db->query($query, current_user()->{id}, ($private ? '1' : '0'), $body);

    my $entry = db->select_row("SELECT * FROM entries WHERE id = ?", db->last_insert_id);
    $entry->{title} = $title;
    $entry->{account_name} = current_user()->{account_name};
    $entry->{nick_name} = current_user()->{nick_name};
    my $entry_mp = mp->pack($entry);
    my $target_users = get_friends(current_user()->{id});
    for my $user_id (@$target_users) {
        my $key = "entries_of_friends:$user_id";
        if (redis->llen($key) > 0) {
            redis->lpush($key, $entry_mp);
        }
    }

    redirect('/diary/entries/'.current_user()->{account_name});
};

post '/diary/comment/:entry_id' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $entry_id = $c->args->{entry_id};
    my $entry = db->select_row('SELECT * FROM entries WHERE id = ?', $entry_id);
    my $entry_user = get_user($entry->{user_id});
    abort_content_not_found() if (!$entry);
    $entry->{is_private} = ($entry->{private} == 1);
    if ($entry->{is_private} && !permitted($entry->{user_id})) {
        abort_permission_denied();
    }
    my $query = 'INSERT INTO comments (entry_id, user_id, comment) VALUES (?,?,?)';
    my $comment = $c->req->param('comment');
    db->query($query, $entry->{id}, current_user()->{id}, $comment);
    my $comment_hash = db->select_row("SELECT * FROM comments WHERE id = ?", db->last_insert_id);
    my $comment_mp = mp->pack({
        %$comment_hash,
        account_name => current_user()->{account_name},
        nick_name    => current_user()->{nick_name},
        entry => {
            %$entry,
            account_name => $entry_user->{account_name},
            nick_name    => $entry_user->{nick_name},
        },
    });

    my $target_users = get_friends(current_user()->{id});
    if ($entry->{is_private}) {
        my %entry_user_friends = map { $_ => 1 } @{get_friends($entry->{user_id})};
        $target_users = [ grep { $entry_user_friends{$_} } @$target_users];
    }
    for my $user_id (@$target_users) {
        my $key = "comments_of_friends:$user_id";
        if (redis->llen($key) > 0) {
            redis->lpush($key, $comment_mp);
        }
    }

    redirect('/diary/entry/'.$entry->{id});
};

get '/footprints' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $query = <<SQL;
SELECT f.user_id AS user_id, f.owner_id AS owner_id, u.account_name AS account_name, u.nick_name AS nick_name, DATE(created_at) AS date, MAX(created_at) as updated
FROM footprints f
JOIN users u ON u.id = f.owner_id
WHERE user_id = ?
GROUP BY user_id, owner_id, DATE(created_at)
ORDER BY updated DESC
LIMIT 50
SQL
    my $footprints = db->select_all($query, current_user()->{id});
    $c->render('footprints.tx', { footprints => $footprints });
};

get '/friends' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $query = 'SELECT * FROM relations WHERE one = ? OR another = ? ORDER BY created_at DESC';
    my %friends = ();
    my $friends = [];
    for my $rel (@{db->select_all($query, current_user()->{id}, current_user()->{id})}) {
        my $key = ($rel->{one} == current_user()->{id} ? 'another' : 'one');
        $friends{$rel->{$key}} ||= do {
            my $friend = get_user($rel->{$key});
            $rel->{account_name} = $friend->{account_name};
            $rel->{nick_name} = $friend->{nick_name};
            push @$friends, $rel;
            $rel;
        };
    }
    #my $friends = [ sort { $a->{created_at} lt $b->{created_at} } values(%friends) ];
    $c->render('friends.tx', { friends => $friends });
};

post '/friends/:account_name' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $account_name = $c->args->{account_name};
    if (!is_friend_account($account_name)) {
        my $user = user_from_account($account_name);
        abort_content_not_found() if (!$user);
        db->query('INSERT INTO relations (one, another) VALUES (?,?), (?,?)', current_user()->{id}, $user->{id}, $user->{id}, current_user()->{id});
        redis->del("comments_of_friends:$_") for (
            current_user()->{id}, $user->{id},
            @{get_friends(current_user()->{id})},
            @{get_friends($user->{id})},
        );
        redirect('/friends');
    }
};

get '/initialize' => sub {
    my ($self, $c) = @_;
    db->query("DELETE FROM relations WHERE id > 500000");
    db->query("DELETE FROM footprints WHERE id > 500000");
    db->query("DELETE FROM entries WHERE id > 500000");
    db->query("DELETE FROM comments WHERE id > 1500000");
    redis->flushall();
};

sub get_friends {
    my $me = shift;
    my $query = 'SELECT another FROM relations WHERE one = ?';
    return [map {$_->{another}} @{db->select_all($query, $me)}];
}

1;
